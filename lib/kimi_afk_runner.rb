# frozen_string_literal: true

# AFK (autonomous) runner for Redmine Kimi Agent.
#
# Picks up unassigned/new tasks from configured projects, creates Kimi sessions,
# sends prompts, and waits for completion — all without human interaction.
#
# Usage:
#   bundle exec rake kimi_agent:afk PROJECT_IDS="1,3" LIMIT=2
#
class KimiAfkRunner
  # Tracker priority (lower = higher priority) — mirrors rm-manager rules
  TRACKER_PRIORITY = {
    'Ошибка'    => 1,
    'Улучшение' => 2,
    'Поддержка' => 3,
    'Ретроспектива' => 4
  }.freeze

  # Statuses that are eligible for auto-execution
  ELIGIBLE_STATUSES = [1].freeze # "Новая"

  # Terminal statuses — skip these
  TERMINAL_STATUSES = [3, 5, 6].freeze # Решена, Закрыта, Отклонена

  def initialize(project_ids:, limit: 1, logger: nil)
    @project_ids = Array(project_ids).map(&:to_i)
    @limit       = limit.to_i
    @logger      = logger || default_logger
  end

  def run
    @logger.info "[AFK] Starting scan — projects: #{@project_ids.join(',')}, limit: #{@limit}"

    issues = fetch_eligible_issues
    if issues.empty?
      @logger.info "[AFK] No eligible issues found."
      return
    end

    @logger.info "[AFK] Found #{issues.size} issue(s): #{issues.map(&:id).join(',')}"

    issues.each do |issue|
      process_issue(issue)
    end

    @logger.info "[AFK] Run complete."
  end

  private

  # ── 1. Fetch eligible issues ─────────────────────────────────────────────

  def fetch_eligible_issues
    cf_id = (Setting.plugin_redmine_kimi_agent['kimi_session_cf_id'] || '14').to_i

    scope = Issue
      .where(project_id: @project_ids)
      .where(status_id: ELIGIBLE_STATUSES)
      .where.not(id: issues_with_active_session(cf_id))
      .limit(50) # fetch more than needed for sorting

    # Sort by tracker priority, then by priority_id, then by created_at
    issues = scope.to_a.sort_by do |i|
      [
        TRACKER_PRIORITY[i.tracker.name] || 99,
        i.priority_id,
        i.created_at
      ]
    end

    issues.first(@limit)
  end

  def issues_with_active_session(cf_id)
    # Find issues where CF #14 has a non-empty value (session exists)
    # We use a subquery or raw SQL for efficiency
    CustomValue
      .where(custom_field_id: cf_id)
      .where.not(value: [nil, ''])
      .pluck(:customized_id)
  end

  # ── 2. Process a single issue ────────────────────────────────────────────

  def process_issue(issue)
    @logger.info "[AFK] Processing issue ##{issue.id} — #{issue.subject.truncate(60)}"

    work_dir = Setting.plugin_redmine_kimi_agent['work_dir'].presence || '/tmp'

    client = KimiWebClient.new

    # Check if Kimi is healthy
    begin
      unless client.health['status'] == 'ok'
        @logger.error "[AFK] Kimi CLI unhealthy, skipping ##{issue.id}"
        return
      end
    rescue => e
      @logger.error "[AFK] Kimi health check failed: #{e.message}, skipping ##{issue.id}"
      return
    end

    # Create session
    begin
      session_data = client.session_create(work_dir: work_dir, create_dir: true)
      session_id = session_data['session_id']
    rescue => e
      @logger.error "[AFK] Failed to create session for ##{issue.id}: #{e.message}"
      return
    end

    # Initialize AFK mode
    begin
      @logger.info "[AFK] Sending /afk to session #{session_id} for ##{issue.id}"
      client.prompt(session_id, '/afk', timeout: 30) {}
      sleep 2
    rescue => e
      @logger.warn "[AFK] /afk failed for ##{issue.id}: #{e.message}"
    end

    # Store session_id in custom field
    cf_id = (Setting.plugin_redmine_kimi_agent['kimi_session_cf_id'] || '14').to_i
    cf = IssueCustomField.find_by(id: cf_id)
    if cf
      issue.custom_field_values = { cf.id => session_id }
      issue.save(validate: false)
    end

    # Build prompt
    credentials = KimiCredentialsProvider.for_issue(issue)
    prompt_text = KimiPromptBuilder.build(issue, credentials: credentials)

    # Create DB record
    kimi_session = KimiSession.create!(
      session_id:  session_id,
      issue:       issue,
      user:        User.current || User.first, # fallback for rake tasks
      status:      KimiSession::STATUS_RUNNING,
      prompt_sent: prompt_text,
      work_dir:    work_dir,
      result_log:  ''
    )

    @logger.info "[AFK] Session #{session_id} created for ##{issue.id}"

    # Execute synchronously (blocking) — AFK mode waits for completion
    timeout        = (Setting.plugin_redmine_kimi_agent['timeout'] || 300).to_i
    truncate_limit = (Setting.plugin_redmine_kimi_agent['truncate_limit'] || 10000).to_i

    accumulated = +''
    begin
      client.prompt(session_id, prompt_text, timeout: timeout) do |chunk|
        accumulated << chunk
      end
      final_status = KimiSession::STATUS_DONE
      @logger.info "[AFK] Session #{session_id} for ##{issue.id} completed successfully"
    rescue => e
      accumulated << "\n\nERROR: #{e.class}: #{e.message}"
      final_status = KimiSession::STATUS_ERROR
      @logger.error "[AFK] Session #{session_id} for ##{issue.id} failed: #{e.message}"
    end

    truncated = accumulated.last(truncate_limit)

    kimi_session.update!(
      status:     final_status,
      result_log: truncated
    )

    # Auto-add note if enabled
    if final_status == KimiSession::STATUS_DONE && Setting.plugin_redmine_kimi_agent['add_issue_note_enabled'] == '1'
      add_issue_note(issue, truncated)
    end

    # Auto-close if enabled
    if final_status == KimiSession::STATUS_DONE && Setting.plugin_redmine_kimi_agent['auto_close'] == '1'
      close_issue(issue)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  def add_issue_note(issue, text)
    limit = (Setting.plugin_redmine_kimi_agent['truncate_limit'] || 10000).to_i
    truncated = text.last(limit)
    issue.init_journal(
      User.current || User.first,
      "🤖 **Kimi Agent (AFK) result:**\n\n```\n#{truncated}\n```"
    )
    issue.save(validate: false)
  rescue => e
    @logger.error "[AFK] Failed to add note to ##{issue.id}: #{e.message}"
  end

  def close_issue(issue)
    status_id = Setting.plugin_redmine_kimi_agent['auto_close_status_id'].presence
    target = if status_id.present?
               IssueStatus.find_by(id: status_id)
             else
               IssueStatus.find_by(is_closed: true)
             end
    return unless target
    issue.update!(status: target)
  rescue => e
    @logger.error "[AFK] Failed to close ##{issue.id}: #{e.message}"
  end

  def default_logger
    require 'logger'
    Logger.new(Rails.root.join('log/kimi_afk.log')).tap do |l|
      l.level = Logger::INFO
      l.formatter = proc do |severity, datetime, progname, msg|
        "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{msg}\n"
      end
    end
  end
end

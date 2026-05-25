class KimiAgentController < ApplicationController
  accept_api_auth :show, :execute, :resume, :stop, :restart, :sync, :escalate, :cancel, :status, :download_log
  before_action :find_project_by_project_id
  before_action :find_issue
  before_action :authorize
  before_action :find_kimi_session_cf, only: [:show, :execute, :resume, :reset, :restart, :sync]

  def show
    @sessions = KimiSession.for_issue(@issue.id).limit(10)
    @client   = KimiWebClient.new
    @healthy  = begin
                  @client.health['status'] == 'ok'
                rescue
                  false
                end
    credentials = KimiCredentialsProvider.for_issue(@issue)
    @preview_prompt = KimiPromptBuilder.build(@issue, credentials: credentials)
    @current_session = @sessions.active.first
    render 'kimi_agent/show'
  end

  def execute
    do_execute
  end

  def resume
    session_id = fetch_session_id_from_cf
    unless session_id.present?
      flash[:error] = l(:kimi_error_no_session)
      redirect_to action: :show and return
    end

    client = KimiWebClient.new
    begin
      data = client.session_get(session_id)
      unless data.is_a?(Hash) && data['session_id'].present?
        flash[:error] = l(:kimi_error_session_not_found)
        redirect_to action: :show and return
      end
    rescue => e
      Rails.logger.warn "[KimiAgent] Resume session_get failed: #{e.message}"
      flash[:error] = l(:kimi_error_session_not_found)
      redirect_to action: :show and return
    end

    credentials = KimiCredentialsProvider.for_issue(@issue)
    prompt_text = KimiPromptBuilder.build(@issue, credentials: credentials)

    kimi_session = KimiSession.find_or_initialize_by(session_id: session_id)
    kimi_session.assign_attributes(
      issue:       @issue,
      user:        User.current,
      status:      KimiSession::STATUS_RUNNING,
      prompt_sent: prompt_text,
      work_dir:    params[:work_dir].presence || Setting.plugin_redmine_kimi_agent['work_dir'].presence,
      result_log:  ''
    )
    kimi_session.save!

    start_prompt_thread(client, kimi_session)
    flash[:notice] = l(:kimi_task_resumed, session_id: session_id.truncate(8))
    redirect_to action: :show
  end

  def stop
    kimi_session = KimiSession.active.for_issue(@issue.id).first
    unless kimi_session
      flash[:error] = l(:kimi_error_no_active_session)
      redirect_to action: :show and return
    end

    client = KimiWebClient.new
    begin
      client.session_delete(kimi_session.session_id)
    rescue => e
      Rails.logger.warn "[KimiAgent] Stop failed: #{e.message}"
    end

    kimi_session.update!(status: KimiSession::STATUS_STOPPED)
    flash[:notice] = l(:kimi_task_stopped)
    redirect_to action: :show
  end

  def cancel
    kimi_session = KimiSession.find(params[:id])
    client = KimiWebClient.new
    begin
      client.session_delete(kimi_session.session_id)
    rescue => e
      Rails.logger.warn "[KimiAgent] Cancel failed: #{e.message}"
    end
    kimi_session.update!(status: KimiSession::STATUS_ERROR)
    flash[:notice] = l(:kimi_task_cancelled)
    redirect_to action: :show
  end

  def reset
    do_reset
    flash[:notice] = l(:kimi_session_reset)
    redirect_to action: :show
  end

  def restart
    do_reset
    do_execute
  end

  def sync
    session_id = fetch_session_id_from_cf
    if session_id.present?
      client = KimiWebClient.new
      begin
        data = client.session_get(session_id)
        kimi_session = KimiSession.find_by(session_id: session_id)
        if kimi_session && data.is_a?(Hash)
          state = data['state'] || data['status']
          if %w[idle stopped error done].include?(state)
            kimi_session.update!(status: state) unless kimi_session.status == state
          end
        end
        flash[:notice] = l(:kimi_sync_done)
      rescue => e
        flash[:error] = l(:kimi_sync_failed, error: e.message)
      end
    else
      flash[:notice] = l(:kimi_no_session_to_sync)
    end
    redirect_to action: :show
  end

  def status
    kimi_session = KimiSession.find(params[:id])
    render json: {
      status:     kimi_session.status,
      result_log: kimi_session.result_log
    }
  end

  def escalate
    manager_id = resolve_manager_user_id
    unless manager_id
      flash[:error] = l(:kimi_error_no_manager)
      redirect_to action: :show and return
    end

    status = IssueStatus.find_by(id: 4)
    unless status
      flash[:error] = l(:kimi_error_status_not_found)
      redirect_to action: :show and return
    end

    @issue.init_journal(User.current, "🤖 **Kimi Agent escalation**\n\nSession failed or stopped. Escalating to manager.")
    @issue.assigned_to_id = manager_id
    @issue.status = status
    @issue.save

    flash[:notice] = l(:kimi_task_escalated, manager: manager_id)
    redirect_to action: :show
  end

  def download_log
    kimi_session = KimiSession.find(params[:id])
    send_data kimi_session.result_log.to_s,
              filename: "kimi-session-#{kimi_session.session_id}-log.txt",
              type: 'text/plain',
              disposition: 'attachment'
  end

  private

  def find_issue
    @issue = Issue.find(params[:issue_id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def find_kimi_session_cf
    cf_id = Setting.plugin_redmine_kimi_agent['kimi_session_cf_id'].presence || '14'
    @kimi_session_cf = IssueCustomField.find_by(id: cf_id.to_i)
  end

  def fetch_session_id_from_cf
    return nil unless @kimi_session_cf
    @issue.custom_field_value(@kimi_session_cf).presence
  end

  def write_session_id_to_cf(session_id)
    return unless @kimi_session_cf
    @issue.custom_field_values = { @kimi_session_cf.id => session_id }
    @issue.save
  end

  def do_reset
    write_session_id_to_cf(nil)
  end

  def do_execute
    work_dir = params[:work_dir].presence ||
               Setting.plugin_redmine_kimi_agent['work_dir'].presence

    client = KimiWebClient.new

    # Step 1 — resolve or create session (validated via kimi-web REST API)
    session_id, is_new = resolve_session(client, work_dir)

    unless session_id
      flash[:error] = l(:kimi_error_no_session)
      redirect_to action: :show and return
    end

    # Step 2 — initialize brand-new session with /afk
    if is_new
      initialize_session_afk(client, session_id)
    end

    # Step 3 — build prompt and persist DB record (always)
    credentials = KimiCredentialsProvider.for_issue(@issue)
    prompt_text = KimiPromptBuilder.build(@issue, credentials: credentials)

    kimi_session = KimiSession.find_or_initialize_by(session_id: session_id)
    kimi_session.assign_attributes(
      issue:       @issue,
      user:        User.current,
      status:      KimiSession::STATUS_RUNNING,
      prompt_sent: prompt_text,
      work_dir:    work_dir,
      result_log:  ''
    )
    kimi_session.save!

    # Step 4 — start async prompt thread (always)
    start_prompt_thread(client, kimi_session)

    flash[:notice] = is_new ?
      l(:kimi_task_started, session_id: session_id.truncate(8)) :
      l(:kimi_task_resumed, session_id: session_id.truncate(8))
    redirect_to action: :show
  end

  # Checks CF for an existing session_id and validates it via kimi-web REST API.
  # Returns [session_id, is_new?]
  def resolve_session(client, work_dir)
    session_id = fetch_session_id_from_cf

    if session_id.present?
      begin
        data = client.session_get(session_id)
        if data.is_a?(Hash) && data['session_id'].present?
          return [session_id, false]
        end
      rescue => e
        Rails.logger.warn "[KimiAgent] Existing session #{session_id} not found via kimi-web: #{e.message}"
      end
    end

    # No valid session — create a new one
    session_data = client.session_create(work_dir: work_dir, create_dir: true)
    new_session_id = session_data['session_id']

    if new_session_id
      write_session_id_to_cf(new_session_id)
      [new_session_id, true]
    else
      [nil, false]
    end
  end

  # Sends /afk to a brand-new session so the agent enters autonomous mode.
  def initialize_session_afk(client, session_id)
    Rails.logger.info "[KimiAgent] Initializing session #{session_id} with /afk"
    begin
      client.prompt(session_id, '/afk', timeout: 30) do |chunk|
        Rails.logger.debug "[KimiAgent] /afk chunk: #{chunk}"
      end
      Rails.logger.info "[KimiAgent] /afk completed for session #{session_id}"
      sleep 2  # let Kimi Web settle before reconnecting
    rescue => e
      Rails.logger.warn "[KimiAgent] /afk failed for session #{session_id}: #{e.message}. Continuing anyway."
    end
  end

  def start_prompt_thread(client, kimi_session)
    prompt_text    = kimi_session.prompt_sent
    timeout        = (Setting.plugin_redmine_kimi_agent['timeout'] || 300).to_i
    truncate_limit = (Setting.plugin_redmine_kimi_agent['truncate_limit'] || 10000).to_i
    sid            = kimi_session.session_id

    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        accumulated = +''
        final_status = KimiSession::STATUS_DONE
        last_error  = nil

        begin
          # Send real prompt with retry
          max_attempts = 3
          attempt = 1
          result = nil
          loop do
            begin
              Rails.logger.info "[KimiAgent] Attempt #{attempt}/#{max_attempts} sending main prompt to session #{sid}"
              result = client.prompt(sid, prompt_text, timeout: timeout) do |chunk|
                accumulated << chunk
              end
              Rails.logger.info "[KimiAgent] Main prompt completed for session #{sid}, length: #{result.length}"
              break
            rescue KimiSessionStuckError, KimiWebClientError, RuntimeError => e
              last_error = e
              Rails.logger.warn "[KimiAgent] Attempt #{attempt} failed: #{e.class}: #{e.message}"
              if attempt >= max_attempts
                raise e
              end
              attempt += 1
              sleep 2
            end
          end

          # Work-around: first prompt on a fresh WS connection may return
          # an empty / very short result. A second call reliably picks up
          # the real response.
          if result.present? && result.length < 200
            Rails.logger.info "[KimiAgent] First prompt result too short (#{result.length} chars), forcing second attempt"
            accumulated = +''
            sleep 5
            result = client.prompt(sid, prompt_text, timeout: timeout) do |chunk|
              accumulated << chunk
            end
            Rails.logger.info "[KimiAgent] Second attempt result length: #{result.length}"
          end

          accumulated = result if result

        rescue KimiSessionStuckError => e
          Rails.logger.warn "[KimiAgent] Session stuck: #{e.message}"
          accumulated << "\n\nERROR: #{e.class}: #{e.message}"
          final_status = KimiSession::STATUS_ERROR
        rescue KimiWebClientError => e
          accumulated << "\n\nERROR: #{e.class}: #{e.message}"
          final_status = KimiSession::STATUS_ERROR
        rescue => e
          accumulated << "\n\nERROR: #{e.class}: #{e.message}"
          final_status = KimiSession::STATUS_ERROR
        end

        truncated = accumulated.last(truncate_limit)

        kimi_session.update!(
          status:     final_status,
          result_log: truncated
        )

        if final_status == KimiSession::STATUS_ERROR
          error_path = Rails.root.join("log", "kimi_agent_errors", "issue_#{@issue.id}_#{Time.now.to_i}.log")
          FileUtils.mkdir_p(error_path.dirname)
          File.write(error_path, <<~ERR)
            Issue: #{@issue.id}
            Session: #{sid}
            Timestamp: #{Time.now.iso8601}
            Status: #{final_status}
            Last error: #{last_error&.class}: #{last_error&.message}
            Result log:
            #{truncated}
          ERR
        end

        if final_status == KimiSession::STATUS_DONE && Setting.plugin_redmine_kimi_agent['add_issue_note_enabled'] == '1'
          add_issue_note(@issue, truncated, User.current)
        end

        if final_status == KimiSession::STATUS_DONE && Setting.plugin_redmine_kimi_agent['auto_close'] == '1'
          close_issue
        end
      end
    end
  end

  def add_issue_note(issue, text, user)
    limit = (Setting.plugin_redmine_kimi_agent['truncate_limit'] || 10000).to_i
    truncated = text.last(limit)
    issue.reload
    issue.init_journal(user, "🤖 **Kimi Agent result:**\n\n```\n#{truncated}\n```")
    issue.save
  end

  def close_issue
    status_id = Setting.plugin_redmine_kimi_agent['auto_close_status_id'].presence
    target = if status_id.present?
               IssueStatus.find_by(id: status_id)
             else
               IssueStatus.find_by(is_closed: true)
             end
    return unless target
    @issue.update!(status: target)
  end

  def resolve_manager_user_id
    KimiPromptBuilder.resolve_manager_user_id(@issue)
  end
end

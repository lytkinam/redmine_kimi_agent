class KimiAgentController < ApplicationController
  before_action :find_project_by_project_id
  before_action :find_issue
  before_action :authorize

  def show
    @sessions = KimiSession.for_issue(@issue.id).limit(10)
    @client   = KimiWebClient.new
    @healthy  = begin
                  @client.health['status'] == 'ok'
                rescue
                  false
                end
    render 'kimi_agent/show'
  end

  def execute
    work_dir = params[:work_dir].presence ||
               Setting.plugin_redmine_kimi_agent['work_dir'].presence

    client = KimiWebClient.new
    session_data = client.session_create(work_dir: work_dir, create_dir: true)
    session_id   = session_data['session_id']

    unless session_id
      flash[:error] = l(:kimi_error_no_session)
      redirect_to action: :show and return
    end

    kimi_session = KimiSession.create!(
      session_id:  session_id,
      issue:       @issue,
      user:        User.current,
      status:      KimiSession::STATUS_RUNNING,
      prompt_sent: build_prompt(@issue, params[:extra_instructions]),
      work_dir:    work_dir,
      result_log:  []
    )

    prompt_text = kimi_session.prompt_sent
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        accumulated = +''
        begin
          client.prompt(session_id, prompt_text, timeout: 300) do |chunk|
            accumulated << chunk
          end
          kimi_session.update!(
            status:     KimiSession::STATUS_DONE,
            result_log: accumulated
          )
          add_issue_note(@issue, accumulated, User.current)
          if Setting.plugin_redmine_kimi_agent['auto_close'] == '1'
            @issue.update!(status: IssueStatus.find_by(is_closed: true))
          end
        rescue => e
          kimi_session.update!(
            status:     KimiSession::STATUS_ERROR,
            result_log: "ERROR: #{e.message}"
          )
        end
      end
    end

    flash[:notice] = l(:kimi_task_started, session_id: session_id.truncate(8))
    redirect_to action: :show
  end

  def cancel
    kimi_session = KimiSession.find(params[:id])
    system("python3 #{kimi_script_path} cancel #{kimi_session.session_id} &")
    kimi_session.update!(status: KimiSession::STATUS_ERROR)
    flash[:notice] = l(:kimi_task_cancelled)
    redirect_to action: :show
  end

  def status
    kimi_session = KimiSession.find(params[:id])
    render json: {
      status:     kimi_session.status,
      result_log: kimi_session.result_log
    }
  end

  private

  def find_issue
    @issue = Issue.find(params[:issue_id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def build_prompt(issue, extra = nil)
    parts = []
    parts << "# Task: #{issue.subject}"
    parts << "\n## Description\n#{issue.description}" if issue.description.present?
    parts << "\n## Tracker: #{issue.tracker.name}"
    parts << "## Priority: #{issue.priority.name}"
    parts << "## Status: #{issue.status.name}"
    parts << "\n## Custom Fields"
    issue.custom_field_values.each do |cfv|
      parts << "- #{cfv.custom_field.name}: #{cfv.value}" if cfv.value.present?
    end
    parts << "\n## Additional Instructions\n#{extra}" if extra.present?
    parts << "\n---\nPlease implement this task completely. " \
             "Create or modify necessary files. " \
             "When done, output a brief summary of changes made."
    parts.join("\n")
  end

  def add_issue_note(issue, text, user)
    issue.init_journal(user, "🤖 **Kimi Agent result:**\n\n```\n#{text.truncate(10_000)}\n```")
    issue.save
  end

  def kimi_script_path
    Rails.root.join('plugins', 'redmine_kimi_agent', 'lib', 'scripts', 'kimi-web-ws.py')
  end
end

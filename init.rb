require_dependency File.expand_path('../lib/kimi_agent_hook', __FILE__)
require_dependency File.expand_path('../lib/kimi_credentials_provider', __FILE__)
require_dependency File.expand_path('../lib/kimi_prompt_builder', __FILE__)
require_dependency File.expand_path('../lib/kimi_web_client', __FILE__)
require_dependency File.expand_path('../app/helpers/kimi_agent_helper', __FILE__)

Redmine::Plugin.register :redmine_kimi_agent do
  name        'Redmine Kimi Agent'
  author      'Custom'
  description 'Send Redmine issues to Kimi Code CLI agent for AI execution'
  version     '1.2.1'
  url         'https://github.com/lytkinam/redmine_kimi_agent'

  settings default: {
    'kimi_host'              => '127.0.0.1',
    'kimi_port'              => '5495',
    'kimi_token'             => '',
    'work_dir'               => '',
    'auto_close'             => '0',
    'auto_close_status_id'   => '',
    'timeout'                => '300',
    'truncate_limit'         => '10000',
    'kimi_session_cf_id'     => '14',
    'add_issue_note_enabled' => '1',
    'credentials_yaml_path'          => '/home/user/.kimi/skills/rm-shared/credentials.yaml',
    'credentials_yaml_container_path' => '/usr/src/redmine/config/rm-shared/credentials.yaml'
  }, partial: 'settings/kimi_agent_settings'

  project_module :kimi_agent do
    permission :use_kimi_agent,    kimi_agent: [:show, :execute, :resume, :sync, :download_log]
    permission :manage_kimi_agent, kimi_agent: [:show, :execute, :resume, :cancel, :stop, :reset, :restart, :sync, :history, :download_log, :escalate]
  end
end

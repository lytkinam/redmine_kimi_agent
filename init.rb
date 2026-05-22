Redmine::Plugin.register :redmine_kimi_agent do
  name        'Redmine Kimi Agent'
  author      'Custom'
  description 'Send Redmine issues to Kimi Code CLI agent for AI execution'
  version     '1.0.0'
  url         'https://github.com/lytkinam/redmine_kimi_agent'

  settings default: {
    'kimi_host'  => '127.0.0.1',
    'kimi_port'  => '5494',
    'kimi_token' => '',
    'work_dir'   => '',
    'auto_close' => '0'
  }, partial: 'settings/kimi_agent_settings'

  menu :issue_menu, :kimi_agent,
       { controller: 'kimi_agent', action: 'show' },
       caption: '🤖 Kimi Agent',
       if: Proc.new { |p| User.current.allowed_to?(:use_kimi_agent, p) }

  project_module :kimi_agent do
    permission :use_kimi_agent,    kimi_agent: [:show, :execute]
    permission :manage_kimi_agent, kimi_agent: [:show, :execute, :cancel, :history]
  end
end

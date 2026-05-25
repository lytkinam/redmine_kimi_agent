class KimiAgentHook < Redmine::Hook::ViewListener
  render_on :view_layouts_base_sidebar, partial: 'kimi_agent/sidebar'
end

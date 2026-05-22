Rails.application.routes.draw do
  scope 'projects/:project_id' do
    scope 'issues/:issue_id' do
      scope 'kimi_agent' do
        get    '/',           to: 'kimi_agent#show',    as: :kimi_agent
        post   '/execute',    to: 'kimi_agent#execute', as: :kimi_agent_execute
        delete '/:id/cancel', to: 'kimi_agent#cancel',  as: :kimi_agent_cancel
        get    '/:id/status', to: 'kimi_agent#status',  as: :kimi_agent_status
      end
    end
  end
end

Rails.application.routes.draw do
  scope 'projects/:project_id' do
    scope 'issues/:issue_id' do
      scope 'kimi_agent' do
        get    '/',                 to: 'kimi_agent#show',        as: :kimi_agent
        post   '/execute',          to: 'kimi_agent#execute',     as: :kimi_agent_execute
        post   '/resume',           to: 'kimi_agent#resume',      as: :kimi_agent_resume
        post   '/stop',             to: 'kimi_agent#stop',        as: :kimi_agent_stop
        post   '/restart',          to: 'kimi_agent#restart',     as: :kimi_agent_restart
        delete '/reset',            to: 'kimi_agent#reset',       as: :kimi_agent_reset
        post   '/sync',             to: 'kimi_agent#sync',        as: :kimi_agent_sync
        post   '/escalate',         to: 'kimi_agent#escalate',    as: :kimi_agent_escalate
        delete '/:id/cancel',       to: 'kimi_agent#cancel',      as: :kimi_agent_cancel
        get    '/:id/status',       to: 'kimi_agent#status',      as: :kimi_agent_status
        get    '/:id/download_log', to: 'kimi_agent#download_log', as: :kimi_agent_download_log
      end
    end
  end
end

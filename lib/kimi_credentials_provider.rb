# frozen_string_literal: true

require 'yaml'

# Provides Redmine REST API credentials for the Kimi agent by reading
# the credentials.yaml file inside the container.
#
# Looks up the assigned user by user_id and returns their api_key + base_url.
# Falls back to plugin settings / ENV if credentials.yaml is missing
# or the user is not found.
#
class KimiCredentialsProvider
  DEFAULT_CONTAINER_PATH = '/usr/src/redmine/config/rm-shared/credentials.yaml'

  def self.for_issue(issue)
    settings = Setting.plugin_redmine_kimi_agent rescue {}
    path     = settings['credentials_yaml_container_path'].presence || DEFAULT_CONTAINER_PATH
    user_id  = issue&.assigned_to_id

    if user_id && File.exist?(path)
      begin
        yaml = YAML.safe_load(File.read(path))
        user = yaml&.dig('users')&.values&.find { |u| u['user_id'].to_s == user_id.to_s }
        if user
          return {
            base_url: user['base_url'] || yaml&.dig('meta', 'base_url') || 'http://localhost:3000',
            api_key:  user['api_key'] || '',
            user_id:  user_id,
            user_login: user['login']
          }
        end
      rescue => e
        Rails.logger.warn "[KimiAgent] Failed to read credentials.yaml: #{e.message}"
      end
    end

    # Fallback: plugin settings / ENV
    {
      base_url: settings['redmine_base_url'].presence || ENV.fetch('REDMINE_BASE_URL', 'http://localhost:3000'),
      api_key:  settings['redmine_api_key'].presence  || ENV.fetch('REDMINE_API_KEY', ''),
      user_id:  user_id,
      user_login: issue&.assigned_to&.login
    }
  end
end

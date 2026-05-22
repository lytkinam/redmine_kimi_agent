module KimiAgentHelper
  def status_icon(status)
    { 'done' => '✅', 'running' => '⏳', 'error' => '❌',
      'pending' => '🕐', 'idle' => '💤' }.fetch(status, '❓')
  end
end

module KimiAgentHelper
  def status_icon(status)
    { 'done' => '✅', 'running' => '⏳', 'error' => '❌',
      'pending' => '🕐', 'idle' => '💤', 'stopped' => '🛑' }.fetch(status, '❓')
  end

  # Deprecated: legacy plain-text prompt builder.
  # Use KimiPromptBuilder.build(issue, credentials: ...) instead.
  def build_prompt(issue, extra = nil)
    credentials = KimiCredentialsProvider.for_issue(issue)
    KimiPromptBuilder.build(issue, credentials: credentials)
  end
end

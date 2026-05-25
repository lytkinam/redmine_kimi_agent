# frozen_string_literal: true

# Builds a structured prompt (JSON contract + primary instruction "kick")
# for Kimi CLI agent execution.
#
# The plugin does NOT resolve skills. It passes:
#   - issue_id, project_id, user_id  → to identify task & executor
#   - bootstrap skill name            → ai-skill-manager
#   - Redmine REST API credentials    → so Kimi can read/write issues
#   - escalation manager user_id      → where to escalate on blocker
#
# Kimi itself:
#   1. Loads ai-skill-manager/SKILL.md
#   2. Reads ~/.kimi/skills/rm-shared/credentials.yaml by user_id
#   3. Collects skills via ai-skill-manager logic
#   4. Loads all skills, reads task via REST API, executes
#
class KimiPromptBuilder
  BOOTSTRAP_SKILL       = 'ai-skill-manager'
  DEFAULT_CREDENTIALS_YAML_PATH = '/home/user/.kimi/skills/rm-shared/credentials.yaml'

  # ── public API ────────────────────────────────────────────────────────────

  def self.build(issue, credentials:)
    new(issue, credentials).build
  end

  # ── instance ──────────────────────────────────────────────────────────────

  def initialize(issue, credentials)
    @issue       = issue
    @credentials = credentials
  end

  def build
    [
      header,
      contract_section,
      kick_section,
      rules_section
    ].join("\n\n")
  end

  private

  # Part 0 — identity frame
  def header
    <<~MD
      # Kimi Agent — Redmine Task Execution

      You are an AI agent. Your sole job is to execute the Redmine task described below.
      Do NOT ask clarifying questions. Do NOT explain your plan in text only. Execute.
    MD
  end

  # Part 1 — JSON contract with all context Kimi needs
  def contract_section
    contract = {
      version: "1.0",
      contract: {
        type:       "redmine-task-execution",
        issue_id:   @issue.id,
        project_id: @issue.project_id,
        user_id:    @issue.assigned_to_id
      },
      bootstrap: {
        skill:                   bootstrap_skill,
        credentials_yaml_path:   credentials_yaml_path
      },
      redmine: {
        base_url: @credentials[:base_url],
        api_key:  @credentials[:api_key]
      },
      context: {
        status:  @issue.status&.name,
        tracker: @issue.tracker&.name
      },
      escalation: {
        manager_user_id: resolve_manager_user_id,
        on_block:        "set_status_4_and_reassign"
      }
    }

    <<~MD
      ## Part 1 — Execution Contract (read-only context)

      ```json
      #{JSON.pretty_generate(contract)}
      ```
    MD
  end

  # Part 2 — mandatory first steps (the "kick")
  def kick_section
    <<~MD
      ## Part 2 — Mandatory First Steps (DO THIS NOW)

      Step 1. Read the file `#{credentials_yaml_path}` using your file tool.
      Step 2. In that file, find the user where `user_id` equals #{@issue.assigned_to_id.inspect}. Extract their `skills` array.
      Step 3. Read the file `~/.kimi/skills/#{bootstrap_skill}/SKILL.md` using your file tool.
      Step 4. Using the Redmine REST API credentials above, call:
         GET #{@credentials[:base_url]}/issues/#{@issue.id}.json?include=attachments,journals,custom_fields
      Step 5. From the task JSON, extract: tracker name, status name, custom field #10 value ("Компетенции (задача)").
      Step 6. Combine: user skills (from step 2) + tracker skill + status skill + CF#10 skills. Remove duplicates. This is your final skill set.
      Step 7. Read EVERY `~/.kimi/skills/{skill_name}/SKILL.md` from your final skill set.
    MD
  end

  # Part 3 — execution rules
  def rules_section
    <<~MD
      ## Part 3 — Execution Rules

      - Follow the loaded skills' instructions exactly.
      - Update the Redmine task via REST API as you work (status, done_ratio, comments).
      - When complete, generate `TSK.#{@issue.id} Результат выполнения.md` and attach it to the issue via POST /uploads.json.
      - If blocked: update status to 4 (Нужен отклик), reassign to manager_user_id #{resolve_manager_user_id.inspect}, explain blocker in a comment.
      - Do NOT output summaries to chat. All results go into Redmine.
    MD
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  def bootstrap_skill
    BOOTSTRAP_SKILL
  end

  def credentials_yaml_path
    Setting.plugin_redmine_kimi_agent['credentials_yaml_path'].presence || DEFAULT_CREDENTIALS_YAML_PATH
  end

  # ProjectCustomField #5 = "АИ Менеджер"
  def self.resolve_manager_user_id(issue)
    return nil unless issue&.project
    cf = issue.project.custom_field_values.find { |v| v.custom_field_id == 5 }
    cf&.value&.to_i
  rescue
    nil
  end

  def resolve_manager_user_id
    self.class.resolve_manager_user_id(@issue)
  end
end

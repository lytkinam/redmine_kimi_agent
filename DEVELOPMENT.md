# Kimi Agent Plugin — Development & Test Log

## Goal
Execute Redmine task #509 via plugin with `/afk` kick + main prompt, without approval requests.

## Successful Calls

### 1. Direct `client.prompt(sid, '/afk')` + `client.prompt(sid, 'Say hello')`
- **Date**: 2026-05-25
- **Method**: Ruby script inside container
- **Result**: SUCCESS — returns "afk mode enabled..." then "Hello! 👋 ..."
- **Code**:
  ```ruby
  client = KimiWebClient.new
  session = client.session_create(work_dir: '/home/user')
  sid = session['session_id']
  client.prompt(sid, '/afk', timeout: 15)
  client.prompt(sid, 'Say hello', timeout: 60)
  ```
- **Key finding**: Works when calling `prompt()` sequentially on SAME session.

### 2. Debug test with full event tracing
- **Date**: 2026-05-25
- **Result**: SUCCESS — showed `TurnBegin`, `ContentPart`, `session_status` sequence.
- **Key finding**: `history_complete` arrives AFTER history events; must reset `turn_began` and `accumulated` at `history_complete`.

## Failures & Root Causes

### F1. WebSocket 403 on non-existent session
- **Symptom**: `RuntimeError: WS handshake failed: invalid_status_code`
- **Cause**: `session_create` returns `{"session_id"=>"..."}`, but `execute_with_resilience` read `session['id']` (nil).
- **Fix**: Changed to `session['session_id']`.

### F2. Main prompt returns text of `/afk` instead of response
- **Symptom**: `result_log` = "afk mode enabled..."
- **Cause**: `ContentPart` from history `/afk` arrives BEFORE `history_complete`; `accumulated` was not cleared.
- **Fix**: Added `accumulated = +''` at `history_complete`.

### F3. `session_status: idle` arrives immediately after `history_complete`
- **Symptom**: `run_single_prompt` returns empty/prematurely.
- **Cause**: Stale `session_status` from previous turn; `prompt_sent == true` triggers early return.
- **Fix**: Added `turn_began` flag; only return after `TurnBegin` of CURRENT prompt.

### F4. Connection closed immediately after sending long prompt
- **Symptom**: `[DEBUG] RPC sent` → `[DEBUG] TurnBegin` → `[DEBUG] CLOSE` → empty result
- **Cause**: `sock.write` may not flush TCP buffer before Kimi Web closes connection.
- **Fix**: Added `sock.flush` after `sock.write(frame.to_s)`.

### F5. Plugin files not synced to Docker container
- **Symptom**: Changes to `/home/user/git/redmine_kimi_agent/` not reflected in Redmine.
- **Cause**: Dockerfile uses `COPY`, not volume mount; plugin is baked into image.
- **Fix**: Use `docker cp` after every edit + `docker restart redmine`.

## Current Code State (working in direct Ruby tests)
- `lib/kimi_web_client.rb`: WebSocket client with AFK kick, stuck detection, retry.
- `app/controllers/kimi_agent_controller.rb`: Added `accept_api_auth`.
- `lib/kimi_prompt_builder.rb`: Structured prompt with JSON contract.

## Next Steps
1. Verify `sock.flush` fixes long-prompt connection close.
2. Test `execute_with_resilience` with 5-second delay after `/afk`.
3. Skip `/afk` for existing sessions where AFK is already enabled.
4. Run end-to-end via Redmine API for issue #509.

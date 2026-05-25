require 'net/http'
require 'json'
require 'uri'
require 'websocket'
require 'socket'
require 'securerandom'

# Custom errors ---------------------------------------------------------------
class KimiSessionStuckError < StandardError; end
class KimiWebClientError   < StandardError; end

# Client for Kimi Code CLI Web Interface (local uvicorn on 127.0.0.1:5494)
class KimiWebClient
  STUCK_TIMEOUT = 900   # 15 minutes without new text = stuck
  MAX_RETRIES   = 2     # create new session + retry this many times

  attr_reader :host, :port, :token

  def initialize(host: nil, port: nil, token: nil)
    settings   = Setting.plugin_redmine_kimi_agent rescue {}
    @host  = host  || settings['kimi_host']  || ENV.fetch('KIMI_WEB_HOST', '127.0.0.1')
    @port  = (port || settings['kimi_port']  || ENV.fetch('KIMI_WEB_PORT', '5495')).to_i
    @token = token || settings['kimi_token'] || ''
  end

  # ─── REST ──────────────────────────────────────────────────────────────────

  def health
    rest_get('/healthz')
  end

  def session_create(work_dir: nil, create_dir: false)
    body = { create_dir: create_dir }
    body[:work_dir] = work_dir if work_dir.present?
    rest_post('/api/sessions/', body)
  end

  def session_get(session_id)
    rest_get("/api/sessions/#{session_id}")
  end

  def session_list
    rest_get('/api/sessions/')
  end

  def session_delete(session_id)
    rest_delete("/api/sessions/#{session_id}")
  end

  # ─── Low-level prompt (sync, one shot) ────────────────────────────────────

  def prompt(session_id, text, timeout: 120, &on_chunk)
    run_single_prompt(session_id, text, timeout: timeout, &on_chunk)
  end

  private

  # ---------------------------------------------------------------------------
  # WebSocket single-prompt runner
  # ---------------------------------------------------------------------------
  def run_single_prompt(session_id, text, timeout:, &on_chunk)
    url = "ws://#{@host}:#{@port}/api/sessions/#{session_id}/stream"
    url += "?token=#{@token}" if @token.present?

    uri       = URI.parse(url)
    handshake = WebSocket::Handshake::Client.new(url: url)
    sock      = TCPSocket.new(uri.host, uri.port)
    sock.write(handshake.to_s)

    until handshake.finished?
      b = sock.read(1)
      raise 'WS connection closed during handshake' if b.nil?
      handshake << b
    end
    raise "WS handshake failed: #{handshake.error}" unless handshake.valid?

    incoming       = WebSocket::Frame::Incoming::Client.new(version: handshake.version)
    history_done   = false
    prompt_sent    = false
    turn_began     = false
    turn_began_at  = nil
    accumulated    = +''
    deadline       = Time.now + timeout
    last_chunk_at  = Time.now
    afk_phase      = text == '/afk'   # true when we are only kicking AFK mode

    send_rpc = ->(method, params = nil, id: SecureRandom.uuid) {
      msg = { jsonrpc: '2.0', method: method, id: id }
      msg[:params] = params if params
      frame = WebSocket::Frame::Outgoing::Client.new(
        version: handshake.version, data: JSON.generate(msg), type: :text
      )
      sock.write(frame.to_s)
      sock.flush
    }

    loop do
      # --- stuck detection ---------------------------------------------------
      if (Time.now - last_chunk_at) > STUCK_TIMEOUT
        sock.close rescue nil
        raise KimiSessionStuckError,
              "No new text for #{STUCK_TIMEOUT}s (last at #{last_chunk_at})"
      end

      raise "KimiWebClient timeout (#{timeout}s)" if Time.now > deadline

      raw = sock.read_nonblock(4096) rescue nil
      unless raw
        sleep 0.01
        next
      end

      incoming << raw

      while (msg = incoming.next)
        case msg.type
        when :text
          data   = JSON.parse(msg.data) rescue next
          method = data['method']

          case method
          when 'history_complete'
            history_done = true
            unless prompt_sent
              send_rpc.call('prompt', { user_input: text })
              prompt_sent = true
              turn_began = false     # reset: wait for TurnBegin of THIS prompt
              accumulated = +''      # discard history text, collect only THIS prompt
            end

          when 'session_status'
            state = data.dig('params', 'state')
            # Ignore stale session_status that arrives right after TurnBegin.
            # Wait at least 2 seconds after TurnBegin before accepting idle.
            just_turned = turn_began_at && (Time.now - turn_began_at) < 2.0
            if prompt_sent && (afk_phase || turn_began) && !just_turned && %w[idle stopped error].include?(state)
              sock.close rescue nil
              return accumulated
            end

          when 'event'
            etype   = data.dig('params', 'type')
            payload = data.dig('params', 'payload') || {}
            if etype == 'TurnBegin'
              turn_began = true
              turn_began_at = Time.now
            end
            # ContentPart carries actual text chunks (including think blocks)
            if etype == 'ContentPart' && payload['type'] == 'text'
              chunk = payload['text'].to_s
              unless chunk.empty?
                accumulated << chunk
                last_chunk_at = Time.now
                on_chunk&.call(chunk)
              end
            end
            # Collect think blocks so result_log is never empty when the model only thinks
            if etype == 'ContentPart' && payload['type'] == 'think'
              chunk = payload['think'].to_s
              unless chunk.empty?
                accumulated << chunk
                last_chunk_at = Time.now
                on_chunk&.call(chunk)
              end
            end
            # Legacy fallbacks
            if %w[agent_text agent_response].include?(etype)
              chunk = payload['text'].to_s
              unless chunk.empty?
                accumulated << chunk
                last_chunk_at = Time.now
                on_chunk&.call(chunk)
              end
            end

          when 'request'
            req_id   = data['id']
            req_type = data.dig('params', 'type')
            if req_type == 'ApprovalRequest'
              # Auto-approve any lingering approval requests.
              # In AFK mode these should not appear, but keep as safety-net.
              frame = WebSocket::Frame::Outgoing::Client.new(
                version: handshake.version,
                data: JSON.generate({ jsonrpc: '2.0', id: req_id, result: { approved: true } }),
                type: :text
              )
              sock.write(frame.to_s)
            end
          end

        when :ping
          pong = WebSocket::Frame::Outgoing::Client.new(
            version: handshake.version, type: :pong, data: msg.data
          )
          sock.write(pong.to_s)

        when :close
          return accumulated
        end
      end
    end
  ensure
    sock&.close rescue nil
  end

  def cleanup_session(session_id)
    session_delete(session_id)
  rescue => e
    Rails.logger.warn "[KimiWebClient] Failed to delete stuck session #{session_id}: #{e.message}"
  end

  def rest_get(path)
    Net::HTTP.start(@host, @port, open_timeout: 5, read_timeout: 10) do |http|
      req = Net::HTTP::Get.new(path)
      add_auth(req)
      resp = http.request(req)
      JSON.parse(resp.body)
    end
  end

  def rest_post(path, body = nil)
    Net::HTTP.start(@host, @port, open_timeout: 5, read_timeout: 10) do |http|
      req = Net::HTTP::Post.new(path)
      add_auth(req)
      if body
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(body)
      end
      resp = http.request(req)
      JSON.parse(resp.body)
    end
  end

  def rest_delete(path)
    Net::HTTP.start(@host, @port, open_timeout: 5, read_timeout: 10) do |http|
      req = Net::HTTP::Delete.new(path)
      add_auth(req)
      http.request(req).code.to_i
    end
  end

  def add_auth(req)
    req['Authorization'] = "Bearer #{@token}" if @token.present?
  end
end

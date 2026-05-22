# redmine_kimi_agent

Redmine плагин для интеграции с **Kimi Code CLI Web Interface**.
Позволяет отправить любую задачу Redmine в Kimi-агента одним кликом.

## Требования

- Redmine 5.x+, Ruby 3.x
- Kimi Code CLI запущен в web-режиме: `kimi web` (слушает на `127.0.0.1:5494`)
- Gem `websocket` (уже в Rails/Redmine)
- Python 3 + `websocket-client` (для fallback: `pip install websocket-client`)

## Установка

```bash
# 1. Скопировать в plugins/
cp -r redmine_kimi_agent /path/to/redmine/plugins/

# 2. (Опционально) скопировать Python-скрипт для fallback
cp kimi-web-ws.py /path/to/redmine/plugins/redmine_kimi_agent/lib/scripts/

# 3. Миграция БД
cd /path/to/redmine
bundle exec rake redmine:plugins:migrate RAILS_ENV=production NAME=redmine_kimi_agent

# 4. Перезапустить Redmine
```

## Настройка

1. Redmine → Администрирование → Плагины → **Kimi Agent** → Настройки
2. Указать host/port Kimi CLI (по умолчанию `127.0.0.1:5494`)
3. В настройках проекта → Модули → включить **Kimi Agent**
4. Настройки → Права доступа → выдать роли `use_kimi_agent`

## Использование

Открыть любую задачу → вкладка **🤖 Kimi Agent** → указать рабочую директорию → **▶ Запустить**.

Агент:
1. Создаёт новую сессию Kimi CLI
2. Формирует промпт из `subject` + `description` + `custom fields` задачи
3. Отправляет через WebSocket (JSON-RPC 2.0)
4. По завершении добавляет результат как комментарий к задаче
5. Опционально закрывает задачу

## Архитектура

```
Redmine Issue
     │
     ▼
KimiAgentController#execute
     │  POST /api/sessions/     → создать сессию
     │  WS /api/sessions/{id}/stream
     │  ├─ history_complete → send prompt
     │  ├─ event.agent_text → накапливать
     │  └─ session_status idle → сохранить результат
     ▼
KimiSession (ActiveRecord)
     │
     ▼
Issue Journal (комментарий с результатом)
```

## Структура

```
redmine_kimi_agent/
├── init.rb
├── app/
│   ├── controllers/kimi_agent_controller.rb
│   ├── models/kimi_session.rb
│   ├── views/kimi_agent/show.html.erb
│   └── helpers/kimi_agent_helper.rb
├── lib/
│   └── kimi_web_client.rb        ← WebSocket + REST клиент
├── db/migrate/
│   └── 001_create_kimi_sessions.rb
└── config/
    ├── routes.rb
    └── locales/{ru,en}.yml
```

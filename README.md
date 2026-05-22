# redmine_kimi_agent

Redmine плагин для интеграции с **Kimi Code CLI Web Interface**.
Позволяет отправить любую задачу Redmine в Kimi-агента одним кликом — агент читает описание задачи, выполняет код, создаёт/изменяет файлы и возвращает результат в комментарии.

---

## Требования

- Redmine 5.x+, Ruby 3.x
- Kimi Code CLI запущен в web-режиме: `kimi web` (слушает на `127.0.0.1:5494`)
- Gem `websocket` (уже есть в Rails/Redmine)
- Python 3 + `websocket-client` (для fallback: `pip install websocket-client`)

---

## 1. Подготовка окружения

Перед установкой плагина убедитесь, что Kimi Code CLI запущен:

```bash
kimi web
# Сервер стартует на http://127.0.0.1:5494
```

Проверка доступности:
```bash
curl http://127.0.0.1:5494/healthz
# {"status":"ok"}
```

---

## 2. Установка плагина

```bash
# 1. Скопировать папку плагина в Redmine
cp -r redmine_kimi_agent /var/www/redmine/plugins/

# 2. (Опционально) скопировать Python-скрипт для fallback
mkdir -p /var/www/redmine/plugins/redmine_kimi_agent/lib/scripts
cp kimi-web-ws.py /var/www/redmine/plugins/redmine_kimi_agent/lib/scripts/

# 3. Запустить миграцию БД (создаётся таблица kimi_sessions)
cd /var/www/redmine
bundle exec rake redmine:plugins:migrate RAILS_ENV=production NAME=redmine_kimi_agent

# 4. Перезапустить Redmine
sudo systemctl restart redmine
```

---

## 3. Настройка в Redmine (один раз)

**Администрирование → Плагины → Kimi Agent → Настройки:**

| Параметр | Значение по умолчанию | Описание |
|---|---|---|
| Kimi Host | `127.0.0.1` | Адрес Kimi CLI сервера |
| Kimi Port | `5494` | Порт Kimi CLI сервера |
| Auth Token | *(пусто)* | Токен, если сервер требует авторизацию |
| Work Dir | `/home/user/projects` | Папка где агент создаёт/изменяет файлы |
| Авто-закрытие | ☐ | Закрывать задачу после успешного выполнения |

Далее:
1. **Настройки проекта → Модули** → включить **Kimi Agent**
2. **Администрирование → Роли и права доступа** → выдать нужным ролям разрешение `use_kimi_agent`

---

## 4. Последовательность работы с задачей

### Шаг 1 — Открыть задачу

Зайти в любую задачу Redmine. В меню задачи появится вкладка **🤖 Kimi Agent**.

### Шаг 2 — Настроить запуск

На странице агента:
- Указать **рабочую директорию** — папка проекта, где агент будет читать и писать файлы
- Опционально добавить **дополнительные инструкции** (`Используй TypeScript`, `Не трогай тесты`)
- Раскрыть `📋 Промпт` — предварительный просмотр того, что будет отправлено агенту

### Шаг 3 — Нажать ▶ Запустить

Под капотом происходит следующее:

```
Redmine (фоновый Ruby thread)
  │
  ├─ REST POST /api/sessions/        → Kimi CLI создаёт изолированную сессию
  │                                    ← session_id: "6726649d-..."
  │
  ├─ Запись KimiSession в БД           status: running
  │
  └─ WebSocket ws://.../stream
       │
       ├─ ← history_complete           сессия готова к работе
       ├─ → prompt { user_input }       отправляем задачу агенту
       │
       ├─ ← event.agent_text           агент стримит текст (накапливается)
       ├─ ← request.ApprovalRequest    агент хочет записать файл — авто-одобряем
       ├─ ← event.tool_call            агент вызывает инструменты (файлы, код)
       │
       └─ ← session_status: idle       агент завершил работу
            │
            ├─ KimiSession → status: done
            ├─ Комментарий к задаче с результатом
            └─ (опц.) Задача закрывается
```

### Шаг 4 — Наблюдать за выполнением

Страница агента **автоматически обновляет статус** каждые 3 секунды.

| Статус | Значение |
|---|---|
| 🕐 `pending` | Сессия создаётся |
| ⏳ `running` | Агент работает |
| ✅ `done` | Завершено успешно |
| ❌ `error` | Ошибка выполнения |

Кнопка **📄 Лог** раскрывает полный вывод агента для каждой сессии.

При необходимости — кнопка **⛔ Отмена** останавливает активную сессию.

### Шаг 5 — Получить результат

После завершения:
1. В **комментариях к задаче** появится запись `🤖 Kimi Agent result:` с резюме изменений
2. В **рабочей директории** (`work_dir`) будут созданы или изменены файлы
3. Если включено авто-закрытие — задача переходит в статус `Closed`

---

## 5. Fallback-цепочка

Если что-то пошло не так, клиент автоматически переключается:

```
Ruby WebSocket (gem websocket)
    ↓ при ошибке
Python fallback (lib/scripts/kimi-web-ws.py через Open3)
    ↓ если скрипт не найден
Ошибка записывается в KimiSession.result_log
```

---

## Архитектура

```
Redmine Issue
     │
     ▼
KimiAgentController#execute
     │  POST /api/sessions/      → создать сессию
     │  WS /api/sessions/{id}/stream
     │  ├─ history_complete  → send prompt
     │  ├─ event.agent_text  → накапливать
     │  └─ session_status idle → сохранить результат
     ▼
KimiSession (ActiveRecord)
     │
     ▼
Issue Journal (комментарий с результатом)
```

---

## Структура файлов

```
redmine_kimi_agent/
├── init.rb                                  ← регистрация плагина, меню, права
├── app/
│   ├── controllers/kimi_agent_controller.rb ← запуск агента, отмена, статус
│   ├── models/kimi_session.rb               ← история сессий в БД
│   ├── views/kimi_agent/show.html.erb       ← UI с live-polling
│   ├── views/settings/_kimi_agent_settings.html.erb
│   └── helpers/kimi_agent_helper.rb
├── lib/
│   ├── kimi_web_client.rb                   ← WebSocket + REST клиент
│   └── scripts/
│       └── kimi-web-ws.py                   ← Python fallback (добавить вручную)
├── db/migrate/
│   └── 001_create_kimi_sessions.rb          ← миграция таблицы
└── config/
    ├── routes.rb
    └── locales/
        ├── ru.yml
        └── en.yml
```

class CreateKimiSessions < ActiveRecord::Migration[6.1]
  def change
    create_table :kimi_sessions do |t|
      t.string     :session_id,  null: false
      t.references :issue,       null: false, foreign_key: true
      t.references :user,        null: false, foreign_key: true
      t.string     :status,      null: false, default: 'pending'
      t.text       :prompt_sent
      t.text       :result_log
      t.string     :work_dir
      t.timestamps null: false
    end
    add_index :kimi_sessions, :session_id, unique: true
    add_index :kimi_sessions, [:issue_id, :created_at]
  end
end

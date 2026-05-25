class KimiSession < ActiveRecord::Base
  belongs_to :issue
  belongs_to :user

  validates :session_id, presence: true
  validates :issue_id,   presence: true


  STATUS_PENDING  = 'pending'
  STATUS_RUNNING  = 'running'
  STATUS_IDLE     = 'idle'
  STATUS_STOPPED  = 'stopped'
  STATUS_ERROR    = 'error'
  STATUS_DONE     = 'done'

  scope :for_issue, ->(issue_id) { where(issue_id: issue_id).order(created_at: :desc) }
  scope :active,    -> { where(status: [STATUS_PENDING, STATUS_RUNNING]) }
end

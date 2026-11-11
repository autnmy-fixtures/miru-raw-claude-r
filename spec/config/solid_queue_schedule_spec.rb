# frozen_string_literal: true

require "rails_helper"
require "yaml"
require "erb"

RSpec.describe "Solid Queue schedule" do
  let(:config) do
    YAML.safe_load(
      ERB.new(Rails.root.join("config/solid_queue.yml").read).result,
      aliases: true
    )
  end

  it "runs daily Stripe subscription reconciliation in default and production" do
    default_task = config.dig("default", "dispatchers", 0, "recurring_tasks", "sync_stripe_subscriptions")
    production_task = config.dig("production", "dispatchers", 0, "recurring_tasks", "sync_stripe_subscriptions")

    expect(default_task).to include(
      "class" => "SyncStripeSubscriptionsJob",
      "schedule" => "0 1 * * *"
    )
    expect(production_task).to include(
      "class" => "SyncStripeSubscriptionsJob",
      "schedule" => "0 1 * * *"
    )
  end

  it "runs monthly report delivery on the first day of the month in default and production" do
    default_task = config.dig("default", "dispatchers", 0, "recurring_tasks", "monthly_reports_delivery")
    production_task = config.dig("production", "dispatchers", 0, "recurring_tasks", "monthly_reports_delivery")

    expect(default_task).to include(
      "class" => "MonthlyReportsDeliveryJob",
      "schedule" => "0 14 1 * * Asia/Kolkata"
    )
    expect(production_task).to include(
      "class" => "MonthlyReportsDeliveryJob",
      "schedule" => "0 14 1 * * Asia/Kolkata"
    )
  end

  it "runs analytics threshold notifications weekly on Monday at 1 AM Eastern" do
    default_task = config.dig("default", "dispatchers", 0, "recurring_tasks", "analytics_threshold_notifications")
    production_task = config.dig("production", "dispatchers", 0, "recurring_tasks", "analytics_threshold_notifications")

    expect(default_task).to include(
      "class" => "Analytics::ThresholdNotificationsJob",
      "schedule" => "0 1 * * 1 America/New_York"
    )
    expect(production_task).to include(
      "class" => "Analytics::ThresholdNotificationsJob",
      "schedule" => "0 1 * * 1 America/New_York"
    )
  end

  it "runs the Timekeeping invoice operation worker on its own queue and sweeps every 5 seconds in the local runtime" do
    task = config.dig("default", "dispatchers", 0, "recurring_tasks", "invoice_operations")
    workers = config.dig("default", "workers")

    expect(task).to include("class" => "Timekeeping::InvoiceOperationsJob", "schedule" => "*/5 * * * * *")
    expect(Fugit.parse_cron(task.fetch("schedule")).seconds).to eq((0..55).step(5).to_a)
    expect(workers).to include(include("queues" => "invoice_operations", "threads" => 1, "processes" => 1))
    expect(Timekeeping::InvoiceOperationsJob.new.queue_name).to eq("invoice_operations")
  end

  it "runs database backups every 30 minutes in production by default" do
    production_task = config.dig("production", "dispatchers", 0, "recurring_tasks", "database_backup")

    expect(production_task).to include(
      "class" => "DatabaseBackupJob",
      "schedule" => "*/30 * * * *"
    )
  end
end

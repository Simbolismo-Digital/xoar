import Config

# Set to :debug to see all cognitive architecture trace logs.
# Set to :info (or higher) to silence them.
config :logger, :default_handler, level: :debug

config :logger, :default_formatter,
  format: {Xoar, :log_format},
  metadata: [:node, :pid, :file, :line]

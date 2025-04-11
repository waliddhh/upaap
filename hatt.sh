#!/bin/bash

# Check if running with sudo instead of requiring root
if [ "$(id -u)" -eq 0 ]; then
  echo "Warning: Running as root is not recommended. Please run with sudo instead."
  read -p "Continue anyway? [y/N] " -n 1 -r
  echo
  [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# Validate email format function
validate_email() {
  local email="$1"
  local regex="^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"
  [[ $email =~ $regex ]] && return 0 || return 1
}

# Install required packages
install_dependencies() {
  echo "Updating packages and installing dependencies..."
  sudo apt-get update -y
  sudo apt-get install -y postfix mailutils tmux dos2unix curl libsasl2-modules
}

# Configure Postfix properly
configure_postfix() {
  local myhostname=${1:-localhost}
  
  echo "Backing up original Postfix configuration..."
  sudo cp /etc/postfix/main.cf /etc/postfix/main.cf.backup.$(date +%Y%m%d%H%M%S)

  echo "Configuring Postfix..."
  sudo tee /etc/postfix/main.cf > /dev/null <<EOL
# Basic configuration
myhostname = $myhostname
inet_interfaces = loopback-only
mydestination = localhost

# Security settings
smtpd_banner = \$myhostname ESMTP
biff = no
append_dot_mydomain = no
readme_directory = no

# TLS configuration (recommended even for local)
smtp_tls_security_level = may
smtp_tls_loglevel = 1

# Rate limiting to avoid being flagged as spam
smtpd_client_message_rate_limit = 100
anvil_rate_time_unit = 60s
smtpd_client_connection_rate_limit = 10

# Queue management
maximal_queue_lifetime = 1d
bounce_queue_lifetime = 1d

# Logging
mailbox_size_limit = 0
recipient_delimiter = +
disable_vrfy_command = yes
EOL

  sudo postfix reload
}

# Create email template
create_email_template() {
  cat > email.html <<EOL
<html>
<head>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8">
</head>
<body>
  <h1>PrimeRewardSpot iPhone 16 Pro</h1>
  <p>Congratulations! You are eligible to win an iPhone 16 Pro.</p>
</body>
</html>
EOL
}

# Create sending script with error handling
create_send_script() {
  local sender_email=$1
  local sender_name=$2
  local email_subject=$3
  local email_list=$4

  cat > send.sh <<EOL
#!/bin/bash

# Logging setup
LOG_FILE="email_send.log"
ERROR_LOG="email_errors.log"
echo "Starting email send at \$(date)" | tee -a \$LOG_FILE

# Validate email list exists
if [ ! -f "$email_list" ]; then
  echo "Error: Email list file not found: $email_list" | tee -a \$ERROR_LOG
  exit 1
fi

# Rate limiting (emails per minute)
MAX_RATE=30
SLEEP_TIME=\$((60 / MAX_RATE))

# Counters
TOTAL=\$(wc -l < "$email_list")
SUCCESS=0
FAILED=0

echo "Starting to send \$TOTAL emails" | tee -a \$LOG_FILE

while IFS= read -r email; do
  # Validate email format
  if ! [[ \$email =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\$ ]]; then
    echo "Invalid email format: \$email" | tee -a \$ERROR_LOG
    ((FAILED++))
    continue
  fi

  # Send email with error handling
  if ! cat <<EOF | /usr/sbin/sendmail -t
To: \$email
From: $sender_name <$sender_email>
Subject: $email_subject
MIME-Version: 1.0
Content-Type: text/html; charset=UTF-8

\$(cat email.html)
EOF
  then
    echo "Failed to send to: \$email" | tee -a \$ERROR_LOG
    ((FAILED++))
  else
    echo "Sent to: \$email" | tee -a \$LOG_FILE
    ((SUCCESS++))
  fi

  # Rate limiting
  sleep \$SLEEP_TIME

done < "$email_list"

echo "Completed: \$SUCCESS successful, \$FAILED failed" | tee -a \$LOG_FILE
EOL

  chmod +x send.sh
}

# Main execution
echo "Starting email setup..."

# Get user inputs with validation
read -p "Enter the custom myhostname (or press Enter for localhost): " myhostname
myhostname=${myhostname:-localhost}

while true; do
  read -p "Enter the sender email address: " sender_email
  if validate_email "$sender_email"; then
    break
  else
    echo "Invalid email format. Please try again."
  fi
done

read -p "Enter the sender name: " sender_name
read -p "Enter the email subject: " email_subject

while true; do
  read -p "Enter the path to your email list file (e.g., germany.txt): " email_list
  if [ -f "$email_list" ]; then
    break
  else
    echo "File not found. Please try again."
  fi
done

# Install and configure
install_dependencies
configure_postfix "$myhostname"
create_email_template
create_send_script "$sender_email" "$sender_name" "$email_subject" "$email_list"

# Start sending in tmux
echo "Starting email sending in tmux session..."
tmux new-session -d -s mail_session "./send.sh"

echo "Setup complete! Your emails are being sent in the background."
echo "To monitor progress:"
echo "  tmux attach -t mail_session"
echo "To view logs:"
echo "  tail -f email_send.log email_errors.log"

# URL Ping Service with AWS Lambda and SNS

A serverless service that monitors website URLs, records their online status, and sends notifications through Amazon SNS when a URL is down.

## Architecture

![Architecture Diagram](https://via.placeholder.com/800x400?text=URL+Ping+Service+Architecture)

- **AWS Lambda**: Pings all URLs at regular intervals (every 5 minutes by default)
- **Amazon S3 (config)**: Holds the list of URLs to check (as a JSON file)
- **Amazon S3 (flags)**: Stores per-URL alert flags to prevent duplicate notifications
- **Amazon SNS**: Sends alert emails when a URL is down and recovery notifications when it's back up
- **Amazon CloudWatch Events**: Triggers the Lambda function on a schedule

## Directory Structure in S3

```
ping-config/
  └── urls.json  → Configuration file with list of URLs to check
flags/
  ├── example.com.flag
  └── other-domain.com.flag
```

## Prerequisites

- AWS CLI installed and configured with appropriate permissions
- Bash shell environment
- An email address to receive notifications

## Installation

1. Clone this repository:
   ```
   git clone https://github.com/yourusername/ping-website-with-lambda-and-cloudwatch.git
   cd ping-website-with-lambda-and-cloudwatch
   ```

2. Copy the `.env.example` file to `.env` and update the configuration values:
   ```
   cp .env.example .env
   ```
   Then edit the `.env` file to:
   - Set your preferred AWS region (default: us-east-1)
   - Add your email address for notifications
   - Optionally customize bucket names and other settings

3. Make the deployment script executable:
   ```
   chmod +x deploy.sh
   ```

4. Run the deployment script:
   ```
   ./deploy.sh
   ```

5. Check your email and confirm the SNS subscription to receive notifications.

## Configuration

### URLs Configuration

The URLs to monitor are stored in a JSON file in the S3 config bucket. The default structure is:

```json
{
  "urls": [
    "https://example.com",
    "https://google.com",
    "https://aws.amazon.com"
  ]
}
```

To update the list of URLs:

1. Create or edit a local `urls.json` file with your URLs
2. Run the deployment script again:
   ```
   ./deploy.sh
   ```
   The script will automatically upload your local `urls.json` file to S3.

Alternatively, you can manually upload it to S3:
   ```
   aws s3 cp urls.json s3://ping-config/urls.json
   ```

If no local `urls.json` file exists, the deployment script will:
1. Use the existing configuration in S3 if it exists
2. Upload the `sample-urls.json` file if no configuration exists in S3

### Lambda Environment Variables

The Lambda function uses the following environment variables:

- `CONFIG_BUCKET`: S3 bucket for the URLs configuration (default: ping-config)
- `CONFIG_KEY`: Key for the URLs configuration file (default: urls.json)
- `FLAGS_BUCKET`: S3 bucket for the alert flags (default: ping-flags)
- `SNS_TOPIC_ARN`: ARN of the SNS topic for notifications

These are automatically set by the deployment script.

## Customization

### Changing the Check Frequency

By default, the Lambda function runs every 5 minutes. To change this:

1. Update the CloudWatch Events rule:
   ```
   aws events put-rule \
       --name ping-urls-every-5-minutes \
       --schedule-expression "rate(10 minutes)" \
       --state ENABLED
   ```

### Adding Custom Headers or Timeout

Edit the `lambda_function.py` file to customize the request headers or timeout:

```python
req = urllib.request.Request(
    url,
    headers={'User-Agent': 'Your Custom User Agent'}
)

with urllib.request.urlopen(req, timeout=15) as response:
    # ...
```

Then redeploy the Lambda function:

```
zip -r lambda_function.zip lambda_function.py
aws lambda update-function-code \
    --function-name url-ping-lambda \
    --zip-file fileb://lambda_function.zip
```

## Cleanup

To remove all resources created by this project:

```bash
# Delete Lambda function
aws lambda delete-function --function-name url-ping-lambda

# Delete CloudWatch Events rule
aws events remove-targets --rule ping-urls-every-5-minutes --ids 1
aws events delete-rule --name ping-urls-every-5-minutes

# Delete SNS topic (replace with your actual ARN)
aws sns delete-topic --topic-arn <your-sns-topic-arn>

# Delete S3 buckets (this will delete all objects in the buckets)
aws s3 rm s3://ping-config --recursive
aws s3 rb s3://ping-config
aws s3 rm s3://ping-flags --recursive
aws s3 rb s3://ping-flags

# Delete IAM role and policy
aws iam detach-role-policy --role-name lambda-url-ping-role --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam detach-role-policy --role-name lambda-url-ping-role --policy-arn <your-policy-arn>
aws iam delete-policy --policy-arn <your-policy-arn>
aws iam delete-role --role-name lambda-url-ping-role
```

## License

This project is licensed under the MIT License - see the LICENSE file for details.

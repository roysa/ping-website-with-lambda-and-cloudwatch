#!/bin/bash
set -e

# Check if .env file exists and source it
if [ -f .env ]; then
    echo "Loading configuration from .env file..."
    source .env
else
    echo "Error: .env file not found."
    echo "Please copy .env.example to .env and update the values."
    exit 1
fi

# Check if email is provided
if [ -z "$EMAIL_FOR_NOTIFICATIONS" ]; then
    echo "Please set EMAIL_FOR_NOTIFICATIONS in your .env file."
    exit 1
fi

echo "Starting deployment..."

# Create S3 buckets if they don't exist
echo "Creating S3 buckets..."
aws s3api create-bucket --bucket $CONFIG_BUCKET --region $REGION || true
aws s3api create-bucket --bucket $FLAGS_BUCKET --region $REGION || true

# Upload sample config to S3
echo "Uploading sample configuration to S3..."
aws s3 cp sample-urls.json s3://$CONFIG_BUCKET/urls.json

# Create SNS topic
echo "Creating SNS topic..."
SNS_TOPIC_ARN=$(aws sns create-topic --name $SNS_TOPIC_NAME --region $REGION --output text --query 'TopicArn')
echo "SNS Topic ARN: $SNS_TOPIC_ARN"

# Subscribe email to SNS topic
echo "Subscribing email to SNS topic..."
aws sns subscribe \
    --topic-arn $SNS_TOPIC_ARN \
    --protocol email \
    --notification-endpoint $EMAIL_FOR_NOTIFICATIONS \
    --region $REGION

echo "Please confirm the subscription by clicking the link in the email sent to $EMAIL_FOR_NOTIFICATIONS"

# Create IAM role for Lambda
echo "Creating IAM role for Lambda..."
ROLE_NAME="lambda-url-ping-role"

# Create trust policy document
cat > trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create role
aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document file://trust-policy.json || true
ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query 'Role.Arn' --output text)

# Create policy document
cat > policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::$CONFIG_BUCKET/*",
        "arn:aws:s3:::$CONFIG_BUCKET",
        "arn:aws:s3:::$FLAGS_BUCKET/*",
        "arn:aws:s3:::$FLAGS_BUCKET"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "sns:Publish"
      ],
      "Resource": "$SNS_TOPIC_ARN"
    }
  ]
}
EOF

# Attach policy to role
POLICY_NAME="lambda-url-ping-policy"
aws iam create-policy --policy-name $POLICY_NAME --policy-document file://policy.json || true
POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='$POLICY_NAME'].Arn" --output text)
aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn $POLICY_ARN || true

# Also attach the AWS managed policy for Lambda basic execution
aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole || true

# Wait for role to propagate
echo "Waiting for IAM role to propagate..."
sleep 10

# Package Lambda function
echo "Packaging Lambda function..."
zip -r lambda_function.zip lambda_function.py

# Create Lambda function
echo "Creating Lambda function..."
aws lambda create-function \
    --function-name $LAMBDA_FUNCTION_NAME \
    --zip-file fileb://lambda_function.zip \
    --handler lambda_function.lambda_handler \
    --runtime python3.9 \
    --role $ROLE_ARN \
    --timeout 30 \
    --environment "Variables={CONFIG_BUCKET=$CONFIG_BUCKET,CONFIG_KEY=urls.json,FLAGS_BUCKET=$FLAGS_BUCKET,SNS_TOPIC_ARN=$SNS_TOPIC_ARN}" \
    --region $REGION || \
aws lambda update-function-code \
    --function-name $LAMBDA_FUNCTION_NAME \
    --zip-file fileb://lambda_function.zip \
    --region $REGION

# Update Lambda configuration
aws lambda update-function-configuration \
    --function-name $LAMBDA_FUNCTION_NAME \
    --environment "Variables={CONFIG_BUCKET=$CONFIG_BUCKET,CONFIG_KEY=urls.json,FLAGS_BUCKET=$FLAGS_BUCKET,SNS_TOPIC_ARN=$SNS_TOPIC_ARN}" \
    --region $REGION

# Create CloudWatch Events rule to trigger Lambda every 5 minutes
echo "Creating CloudWatch Events rule..."
RULE_NAME="ping-urls-every-5-minutes"
aws events put-rule \
    --name $RULE_NAME \
    --schedule-expression "rate(5 minutes)" \
    --state ENABLED \
    --region $REGION

# Add permission for CloudWatch Events to invoke Lambda
aws lambda add-permission \
    --function-name $LAMBDA_FUNCTION_NAME \
    --statement-id "AllowCloudWatchEventsInvoke" \
    --action "lambda:InvokeFunction" \
    --principal "events.amazonaws.com" \
    --source-arn $(aws events describe-rule --name $RULE_NAME --region $REGION --query 'Arn' --output text) \
    --region $REGION || true

# Set Lambda as target for CloudWatch Events rule
aws events put-targets \
    --rule $RULE_NAME \
    --targets "Id"="1","Arn"="$(aws lambda get-function --function-name $LAMBDA_FUNCTION_NAME --region $REGION --query 'Configuration.FunctionArn' --output text)" \
    --region $REGION

# Clean up temporary files
rm -f trust-policy.json policy.json lambda_function.zip

echo "Deployment completed successfully!"
echo "The Lambda function will now run every 5 minutes to check the URLs."
echo "Please check your email and confirm the SNS subscription to receive notifications."

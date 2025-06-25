import json
import urllib.request
import boto3
import os
import logging

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    """
    Lambda function that pings URLs from a config file in S3,
    checks their status, and sends notifications via SNS if a URL is down.
    """
    # Get environment variables
    config_bucket = os.environ.get('CONFIG_BUCKET', 'ping-config')
    config_key = os.environ.get('CONFIG_KEY', 'urls.json')
    flags_bucket = os.environ.get('FLAGS_BUCKET', 'ping-flags')
    sns_topic_arn = os.environ.get('SNS_TOPIC_ARN')
    
    if not sns_topic_arn:
        logger.error("SNS_TOPIC_ARN environment variable is not set")
        return {
            'statusCode': 500,
            'body': json.dumps('SNS_TOPIC_ARN environment variable is not set')
        }
    
    # Initialize AWS clients
    s3_client = boto3.client('s3')
    sns_client = boto3.client('sns')
    
    try:
        # Get URLs from S3 config
        response = s3_client.get_object(Bucket=config_bucket, Key=config_key)
        urls_config = json.loads(response['Body'].read().decode('utf-8'))
        urls = urls_config.get('urls', [])
        
        results = []
        
        # Ping each URL
        for url in urls:
            status = ping_url(url)
            flag_key = f"flags/{get_domain_from_url(url)}.flag"
            
            # Check if flag exists
            flag_exists = check_flag_exists(s3_client, flags_bucket, flag_key)
            
            if not status['is_up']:
                # URL is down
                if not flag_exists:
                    # Create flag and send notification
                    create_flag(s3_client, flags_bucket, flag_key)
                    send_notification(sns_client, sns_topic_arn, url, status['status_code'], status['error'])
                    logger.info(f"URL {url} is down. Notification sent.")
                else:
                    logger.info(f"URL {url} is still down. Flag exists, no notification sent.")
            else:
                # URL is up
                if flag_exists:
                    # Remove flag
                    delete_flag(s3_client, flags_bucket, flag_key)
                    # Send recovery notification
                    send_recovery_notification(sns_client, sns_topic_arn, url)
                    logger.info(f"URL {url} is back up. Flag removed and recovery notification sent.")
                else:
                    logger.info(f"URL {url} is up.")
            
            results.append({
                'url': url,
                'status': status,
                'flag_exists': flag_exists
            })
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'URL ping completed',
                'results': results
            })
        }
    
    except Exception as e:
        logger.error(f"Error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps(f'Error: {str(e)}')
        }

def ping_url(url):
    """
    Ping a URL and return its status.
    """
    try:
        if not url.startswith(('http://', 'https://')):
            url = 'https://' + url
        
        req = urllib.request.Request(
            url,
            headers={'User-Agent': 'AWS Lambda URL Ping Service'}
        )
        
        with urllib.request.urlopen(req, timeout=10) as response:
            status_code = response.getcode()
            return {
                'is_up': 200 <= status_code < 300,
                'status_code': status_code,
                'error': None
            }
    except urllib.error.HTTPError as e:
        return {
            'is_up': False,
            'status_code': e.code,
            'error': str(e)
        }
    except Exception as e:
        return {
            'is_up': False,
            'status_code': None,
            'error': str(e)
        }

def get_domain_from_url(url):
    """
    Extract domain from URL for flag naming.
    """
    url = url.replace('http://', '').replace('https://', '')
    return url.split('/')[0].replace(':', '_')

def check_flag_exists(s3_client, bucket, key):
    """
    Check if a flag file exists in S3.
    """
    try:
        s3_client.head_object(Bucket=bucket, Key=key)
        return True
    except:
        return False

def create_flag(s3_client, bucket, key):
    """
    Create a flag file in S3.
    """
    s3_client.put_object(
        Bucket=bucket,
        Key=key,
        Body=json.dumps({
            'timestamp': int(boto3.client('sts').get_caller_identity()['ResponseMetadata']['HTTPHeaders']['date']),
            'status': 'down'
        })
    )

def delete_flag(s3_client, bucket, key):
    """
    Delete a flag file from S3.
    """
    s3_client.delete_object(Bucket=bucket, Key=key)

def send_notification(sns_client, topic_arn, url, status_code, error):
    """
    Send a notification via SNS when a URL is down.
    """
    subject = f"ALERT: {url} is DOWN"
    message = f"""
    The URL {url} is currently DOWN.
    
    Status Code: {status_code if status_code else 'N/A'}
    Error: {error}
    
    This is an automated message from the URL Ping Service.
    """
    
    sns_client.publish(
        TopicArn=topic_arn,
        Subject=subject,
        Message=message
    )

def send_recovery_notification(sns_client, topic_arn, url):
    """
    Send a recovery notification via SNS when a URL is back up.
    """
    subject = f"RESOLVED: {url} is back UP"
    message = f"""
    The URL {url} is now back UP.
    
    This is an automated message from the URL Ping Service.
    """
    
    sns_client.publish(
        TopicArn=topic_arn,
        Subject=subject,
        Message=message
    )

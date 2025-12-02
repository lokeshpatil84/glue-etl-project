import json
import boto3

glue_client = boto3.client('glue')

def lambda_handler(event, context):
    # Extract bucket/key from S3 event
    if 'Records' in event:
        for record in event['Records']:
            bucket = record['s3']['bucket']['name']
            key = record['s3']['object']['key']
            print(f"Triggered by: s3://{bucket}/{key}")
    
    # Start Glue Job
    job_name = 'daily-csv-processor-etl-job'  # Hardcode for simplicity, or use env var
    try:
        response = glue_client.start_job_run(JobName=job_name)
        return {
            'statusCode': 200,
            'body': json.dumps(f'Glue job started: {response["JobRunId"]}')
        }
    except Exception as e:
        return {
            'statusCode': 500,
            'body': json.dumps(f'Error: {str(e)}')
        }
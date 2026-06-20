import os
import csv
import urllib.request
import json
import boto3
from datetime import datetime, timedelta, timezone

def lambda_handler(event, context):
    # 1. Get current date in JST (UTC+9)
    jst = timezone(timedelta(hours=9))
    today_jst = datetime.now(jst)
    
    # Calculate Wareki year (Reiwa year = Gregorian year - 2018)
    gregorian_year = today_jst.year
    reiwa_year = gregorian_year - 2018
    today_wareki = f"R{reiwa_year:02d}/{today_jst.month:02d}/{today_jst.day:02d}"
    
    print(f"Today JST: {today_jst.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"Today Wareki format: {today_wareki}")
    
    # 2. Read from S3
    s3_bucket = os.environ.get("S3_BUCKET")
    s3_key = os.environ.get("S3_KEY", "schedule_dates.csv")
    
    if not s3_bucket:
        print("Error: S3_BUCKET environment variable is not set!")
        return {"statusCode": 500, "body": "S3_BUCKET is not set"}
        
    matching_rows = []
    
    try:
        s3 = boto3.client("s3")
        response = s3.get_object(Bucket=s3_bucket, Key=s3_key)
        # Read S3 object content and decode as string
        csv_data = response['Body'].read().decode('utf-8').splitlines()
        
        reader = csv.reader(csv_data)
        header = next(reader, None) # Skip header
        for row in reader:
            if not row or len(row) < 3:
                continue
            date_val, court_name, category = row[0], row[1], row[2]
            if date_val.strip() == today_wareki:
                # Exclude agricultural land (農地 and 特別売却（農地）)
                if "農地" in category:
                    continue
                # Replace '通常' with '期間入札'
                if category == "通常":
                    category = "期間入札"
                matching_rows.append((court_name, category))
    except Exception as e:
        error_msg = f"Failed to read schedule data from S3: {str(e)}"
        print(error_msg)
        return {"statusCode": 500, "body": error_msg}
                
    # 3. Format message
    if not matching_rows:
        print("No matching records found for today. Skipping Discord notification.")
        return {"statusCode": 200, "body": "No matches for today. Notification skipped."}

    category_priority = {
        "期間入札": 0,
        "特別売却": 1
    }
    matching_rows.sort(key=lambda x: category_priority.get(x[1], 9))
    
    date_display = today_jst.strftime("%Y/%m/%d")
    message_lines = [f"【本日の競売閲覧開始日一覧 ({date_display})】"]
    
    for court_name, category in matching_rows:
        message_lines.append(f"・{court_name} ({category})")
        
    message_lines.append("")
    message_lines.append("BIT (不動産競売物件情報サイト): https://www.bit.courts.go.jp/")
    
    message = "\n".join(message_lines)
    print("Prepared message:")
    print(message)
    
    # 4. Send to Discord Webhook
    webhook_url = os.environ.get("DISCORD_WEBHOOK_URL")
    if not webhook_url:
        print("Error: DISCORD_WEBHOOK_URL environment variable is not set!")
        return {"statusCode": 400, "body": "DISCORD_WEBHOOK_URL is not set"}
        
    payload = {"content": message}
    req_data = json.dumps(payload).encode("utf-8")
    
    req = urllib.request.Request(
        webhook_url,
        data=req_data,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "Mozilla/5.0 (AWS Lambda; Python)"
        }
    )
    
    try:
        with urllib.request.urlopen(req) as res:
            response_body = res.read().decode("utf-8")
            print(f"Discord response: {res.status} - {response_body}")
    except Exception as e:
        print(f"Failed to send message to Discord: {e}")
        return {"statusCode": 500, "body": f"Failed to send to Discord: {e}"}
        
    return {"statusCode": 200, "body": "Success"}

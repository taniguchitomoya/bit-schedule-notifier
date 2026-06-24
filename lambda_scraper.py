import os
import re
import csv
import time
import requests
import boto3
from bs4 import BeautifulSoup
from urllib.parse import urljoin, urlparse, parse_qs

# Configuration
BASE_URL = "https://www.bit.courts.go.jp/schedule/index.html"
DOWNLOAD_DIR = "/tmp/download"
OUTPUT_CSV = "/tmp/schedule_dates.csv"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.212 Safari/537.36"
}

def parse_wareki_date(date_str):
    """
    Parses Ryy/mm/dd date string into a comparable tuple (year, month, day).
    Example: 'R08/04/24' -> (2026, 4, 24)
    """
    m = re.match(r'R(\d+)/(\d+)/(\d+)', date_str.strip())
    if m:
        # Reiwa Year 1 is 2019, so Reiwa Year Y is 2018 + Y
        year = 2018 + int(m.group(1))
        month = int(m.group(2))
        day = int(m.group(3))
        return (year, month, day)
    # Default fallback for sorting unparseable dates
    return (9999, 12, 31)

def lambda_handler(event, context):
    s3_bucket = os.environ.get("S3_BUCKET")
    s3_key = os.environ.get("S3_KEY", "schedule_dates.csv")
    dev_discord_webhook_url = os.environ.get("DEV_DISCORD_WEBHOOK_URL") # Optional: dev/error notification
    
    if not s3_bucket:
        print("Error: S3_BUCKET environment variable is not set!")
        return {"statusCode": 400, "body": "S3_BUCKET is not set"}
        
    try:
        os.makedirs(DOWNLOAD_DIR, exist_ok=True)
        index_path = os.path.join(DOWNLOAD_DIR, "index.html")
        
        # Download main index page
        print(f"Downloading main index from {BASE_URL}...")
        res = requests.get(BASE_URL, headers=HEADERS)
        res.raise_for_status()
        res.encoding = "utf-8"
        with open(index_path, "w", encoding="utf-8") as f:
            f.write(res.text)
            
        with open(index_path, "r", encoding="utf-8") as f:
            soup = BeautifulSoup(f.read(), "html.parser")
            
        # Extract court URLs and names
        courts = []
        for a in soup.find_all("a"):
            href = a.get("href", "")
            if "courtId=" in href:
                name = a.get_text(strip=True)
                full_url = urljoin(BASE_URL, href)
                parsed_url = urlparse(full_url)
                court_id = parse_qs(parsed_url.query).get("courtId", [None])[0]
                if court_id:
                    courts.append({
                        "name": name,
                        "url": full_url,
                        "court_id": court_id
                    })
                    
        print(f"Found {len(courts)} courts/branches in the index.")
        
        # Download and parse each court's page
        records = []
        for i, court in enumerate(courts, 1):
            court_name = court["name"]
            court_id = court["court_id"]
            court_url = court["url"]
            
            file_path = os.path.join(DOWNLOAD_DIR, f"court_{court_id}.html")
            
            print(f"[{i}/{len(courts)}] Downloading schedule for {court_name} (ID: {court_id})...")
            try:
                res = requests.get(court_url, headers=HEADERS)
                res.raise_for_status()
                res.encoding = "utf-8"
                with open(file_path, "w", encoding="utf-8") as f:
                    f.write(res.text)
                time.sleep(0.5) # Polite delay
            except Exception as e:
                print(f"Failed to download {court_name}: {e}")
                continue
                
            # Parse the page
            try:
                with open(file_path, "r", encoding="utf-8") as f:
                    court_soup = BeautifulSoup(f.read(), "html.parser")
                    
                found_dates = False
                for table in court_soup.find_all("table", class_="bit__scrollTable_table"):
                    headers = [th.get_text(strip=True) for th in table.find_all("th")]
                    if not headers:
                        continue
                    
                    date_col_name = None
                    if "閲覧開始日" in headers:
                        date_col_name = "閲覧開始日"
                    elif "特別売却閲覧開始日" in headers:
                        date_col_name = "特別売却閲覧開始日"
                        
                    if date_col_name:
                        idx = headers.index(date_col_name)
                        nouchi_idx = headers.index("農地") if "農地" in headers else -1
                        # Find body table in the same scroll table container
                        parent = table.find_parent("div", class_="bit__scrollTable")
                        if parent:
                            body_div = parent.find("div", class_="bit__scrollTable_body")
                            body_table = body_div.find("table") if body_div else None
                            if body_table:
                                rows = body_table.find_all("tr")
                                for row in rows:
                                    cells = [td.get_text(strip=True) for td in row.find_all("td")]
                                    if len(cells) > idx:
                                        date_val = cells[idx].strip()
                                        if date_val:
                                            nouchi_val = ""
                                            if nouchi_idx != -1 and len(cells) > nouchi_idx:
                                                nouchi_val = cells[nouchi_idx].strip()
                                            is_nouchi = "★" in nouchi_val
                                            
                                            if date_col_name == "閲覧開始日":
                                                category = "農地" if is_nouchi else "通常"
                                            else:
                                                category = "特別売却（農地）" if is_nouchi else "特別売却"
                                            
                                            records.append({
                                                "date": date_val,
                                                "court_name": court_name,
                                                "category": category
                                            })
                                            found_dates = True
                if not found_dates:
                    print(f"No schedule dates found for {court_name}.")
            except Exception as e:
                print(f"Error parsing {court_name}: {e}")
                
        # Sort records by date
        category_priority = {
            "通常": 0,
            "特別売却": 1,
            "農地": 2,
            "特別売却（農地）": 3
        }
        records.sort(key=lambda x: (parse_wareki_date(x["date"]), category_priority.get(x["category"], 9)))
        
        # Write to CSV
        with open(OUTPUT_CSV, "w", encoding="utf-8", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["日付", "地裁・支部の名称", "区分"])
            for record in records:
                writer.writerow([record["date"], record["court_name"], record["category"]])
                
        print(f"Extraction completed. Saved {len(records)} records locally.")
        
        # Upload to S3
        print(f"Uploading to S3 bucket '{s3_bucket}' with key '{s3_key}'...")
        s3 = boto3.client("s3")
        s3.upload_file(OUTPUT_CSV, s3_bucket, s3_key)
        print("Upload successful!")
        
        return {
            "statusCode": 200,
            "body": f"Successfully scraped and uploaded {len(records)} records to S3."
        }
        
    except Exception as e:
        error_msg = f"Scraper execution failed: {str(e)}"
        print(error_msg)
        
        # Send error notification to Discord if webhook URL is configured
        if dev_discord_webhook_url:
            try:
                import json
                import urllib.request
                payload = {"content": f"⚠️ **【bitschedule-scraperエラー】**\n{error_msg}"}
                req_data = json.dumps(payload).encode("utf-8")
                req = urllib.request.Request(
                    dev_discord_webhook_url,
                    data=req_data,
                    headers={"Content-Type": "application/json", "User-Agent": "AWS Lambda"}
                )
                with urllib.request.urlopen(req) as res:
                    pass
            except Exception as notify_err:
                print(f"Failed to send error notification to Discord: {notify_err}")
                
        return {
            "statusCode": 500,
            "body": error_msg
        }

import os
import re
import csv
import time
import requests
from bs4 import BeautifulSoup
from urllib.parse import urljoin, urlparse, parse_qs

# Configuration
BASE_URL = "https://www.bit.courts.go.jp/schedule/index.html"
DOWNLOAD_DIR = "download"
OUTPUT_CSV = "schedule_dates.csv"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.212 Safari/537.36"
}
CACHE_TTL_SECONDS = 12 * 60 * 60  # Cache duration (12 hours)

def is_cache_valid(filepath, ttl_seconds):
    """
    Checks if a file exists and its modification time is within the TTL.
    """
    if not os.path.exists(filepath):
        return False
    file_mtime = os.path.getmtime(filepath)
    return (time.time() - file_mtime) < ttl_seconds


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

def main():
    # 1. Create download directory
    os.makedirs(DOWNLOAD_DIR, exist_ok=True)
    
    index_path = os.path.join(DOWNLOAD_DIR, "index.html")
    
    # 2. Download main index page
    if not is_cache_valid(index_path, CACHE_TTL_SECONDS):
        print(f"Downloading main index from {BASE_URL}...")
        res = requests.get(BASE_URL, headers=HEADERS)
        res.raise_for_status()
        res.encoding = "utf-8"
        with open(index_path, "w", encoding="utf-8") as f:
            f.write(res.text)
    else:
        print(f"Using cached index page at {index_path}.")
        
    with open(index_path, "r", encoding="utf-8") as f:
        soup = BeautifulSoup(f.read(), "html.parser")
        
    # 3. Extract court URLs and names
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
    
    # 4. Download and parse each court's page
    records = []
    
    for i, court in enumerate(courts, 1):
        court_name = court["name"]
        court_id = court["court_id"]
        court_url = court["url"]
        
        file_path = os.path.join(DOWNLOAD_DIR, f"court_{court_id}.html")
        
        # Download if cache is invalid or missing
        if not is_cache_valid(file_path, CACHE_TTL_SECONDS):
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
        else:
            print(f"[{i}/{len(courts)}] Using cached schedule for {court_name} (ID: {court_id})")
            
        # Parse the page
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                court_soup = BeautifulSoup(f.read(), "html.parser")
                
            # Find the Period Bidding (期間入札) table
            found_dates = False
            for table in court_soup.find_all("table", class_="bit__scrollTable_table"):
                headers = [th.get_text(strip=True) for th in table.find_all("th")]
                if not headers:
                    continue
                
                # Check for date column in headers
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
                                    if date_val: # Only keep non-empty values
                                        # Determine if agricultural land (★ is present in nouchi column)
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
                # Sometimes a court might not have any active schedule listed
                print(f"No schedule dates found for {court_name}.")
        except Exception as e:
            print(f"Error parsing {court_name}: {e}")
            
    # 5. Sort records by date (chronologically), prioritizing category (通常/期間入札 first)
    category_priority = {
        "通常": 0,
        "特別売却": 1,
        "農地": 2,
        "特別売却（農地）": 3
    }
    # R08/04/24 format will be parsed correctly using parse_wareki_date
    records.sort(key=lambda x: (parse_wareki_date(x["date"]), category_priority.get(x["category"], 9)))
    
    
    # 6. Write to CSV
    with open(OUTPUT_CSV, "w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        # Write header
        writer.writerow(["日付", "地裁・支部の名称", "区分"])
        for record in records:
            writer.writerow([record["date"], record["court_name"], record["category"]])
            
    print(f"\nExtraction completed. Saved {len(records)} records to {OUTPUT_CSV}.")

if __name__ == "__main__":
    main()

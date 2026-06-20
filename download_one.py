import os
import requests
from bs4 import BeautifulSoup

# Create download directory if not exists
os.makedirs("download", exist_ok=True)

url = "https://www.bit.courts.go.jp/app/schedule/pr005/h01?courtId=38111"
headers = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.212 Safari/537.36"
}

print(f"Downloading {url}...")
res = requests.get(url, headers=headers)
res.raise_for_status()

# Save to download directory
filepath = os.path.join("download", "court_38111.html")
with open(filepath, "w", encoding="utf-8") as f:
    f.write(res.text)

print(f"Saved to {filepath}")

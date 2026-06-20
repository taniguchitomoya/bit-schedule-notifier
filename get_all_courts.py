import requests
from bs4 import BeautifulSoup
from urllib.parse import urljoin

url = "https://www.bit.courts.go.jp/schedule/index.html"
headers = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.212 Safari/537.36"
}

print(f"Fetching index from {url}...")
res = requests.get(url, headers=headers)
res.raise_for_status()

soup = BeautifulSoup(res.text, "html.parser")
links = soup.find_all("a")

courts = []
for a in links:
    href = a.get("href", "")
    if "courtId=" in href:
        full_url = urljoin(url, href)
        name = a.get_text(strip=True)
        courts.append((name, full_url))

print(f"Found {len(courts)} court/branch links.")
for name, link in courts[:10]:
    print(f"- {name}: {link}")

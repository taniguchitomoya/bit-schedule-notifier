from bs4 import BeautifulSoup

with open("download/court_38111.html", "r", encoding="utf-8") as f:
    soup = BeautifulSoup(f.read(), "html.parser")

# Get court name from the title/header or details
# Let's find: "年間売却スケジュール／札幌地方裁判所本庁" or similar
h1_text = soup.find("h1").get_text(strip=True) if soup.find("h1") else ""
print("H1 Text:", h1_text)

court_name = ""
if "年間売却スケジュール／" in h1_text:
    court_name = h1_text.split("年間売却スケジュール／")[1].split()[0]
else:
    # Try finding paragraph with class 'font-weight-bold'
    p_name = soup.find("p", class_="font-weight-bold")
    if p_name:
        court_name = p_name.get_text(strip=True)

print("Extracted Court Name:", court_name)

# Now find tables
for table in soup.find_all("table", class_="bit__scrollTable_table"):
    headers = [th.get_text(strip=True) for th in table.find_all("th")]
    if not headers:
        continue
    print("Headers:", headers)
    
    if "閲覧開始日" in headers:
        idx = headers.index("閲覧開始日")
        # Find the tbody
        # Note: In the HTML, the tables in the header and body are separated:
        # <div class="bit__scrollTable_header col-12 px-0"> <table ...> <thead> ...
        # <div class="bit__scrollTable_body col-12 px-0"> <table ...> <tbody> ...
        # So they are two separate tables!
        # Let's find the matching body table.
        # The body table is usually the next sibling table or inside the parent div.
        # Let's see: the header table and body table are both inside a parent div class="bit__scrollTable row mx-0".
        parent = table.find_parent("div", class_="bit__scrollTable")
        if parent:
            body_table = parent.find("div", class_="bit__scrollTable_body").find("table") if parent.find("div", class_="bit__scrollTable_body") else None
            if body_table:
                rows = body_table.find_all("tr")
                for row in rows:
                    cells = [td.get_text(strip=True) for td in row.find_all("td")]
                    if len(cells) > idx:
                        date_val = cells[idx]
                        print("Found viewing start date:", date_val)

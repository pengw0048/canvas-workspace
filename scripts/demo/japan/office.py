"""Writes the budget sheet and itinerary document for the trip demo: office.py <dir>. Needs openpyxl and python-docx."""
import sys
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment
from docx import Document
from docx.shared import Pt

out = sys.argv[1]
wb = Workbook()
ws = wb.active
ws.title = "预算"
rows = [("项目", "单价（元）", "数量", "小计"),
        ("机票（往返）", 4200, 3), ("东京酒店（每晚）", 900, 2), ("京都民宿（每晚）", 1100, 3),
        ("JR 新干线", 900, 3), ("餐饮（每人每天）", 300, 15), ("门票与交通", 1200, 1)]
ws.append(rows[0])
for i, (name, price, qty) in enumerate(rows[1:], start=2):
    ws.append((name, price, qty, f"=B{i}*C{i}"))
n = len(rows)
ws.append(("合计", None, None, f"=SUM(D2:D{n})"))
for c in ws[1]:
    c.font = Font(bold=True, color="FFFFFF")
    c.fill = PatternFill("solid", fgColor="E5484D")
for c in ws[n + 1]:
    c.font = Font(bold=True)
for col, w in zip("ABCD", (20, 12, 8, 12)):
    ws.column_dimensions[col].width = w
wb.save(f"{out}/旅行预算.xlsx")

d = Document()
d.add_heading("日本 · 四月 行程", 0)
d.add_paragraph("小安、妈妈、哥哥 · 4月10日 – 4月16日")
days = [("4月10日 · 东京", ["羽田机场到达，入住浅草", "晚上：晴空塔"]),
        ("4月11日 · 东京", ["筑地场外市场早餐", "浅草寺、上野公园赏樱"]),
        ("4月12日 · 京都", ["新干线 09:00 希望号", "入住花见小路民宿，晚上逛祇园"]),
        ("4月13日 · 京都", ["伏见稻荷（早点去）", "下午：清水寺、抹茶"]),
        ("4月14日 · 奈良", ["电车去奈良公园", "东大寺"])]
for title, items in days:
    d.add_heading(title, 2)
    for it in items:
        d.add_paragraph(it, style="List Bullet")
d.add_heading("行程图", 2)
d.add_paragraph("")
for p in d.paragraphs:
    for r in p.runs:
        r.font.size = Pt(12)
d.save(f"{out}/日本行程.docx")
print("wrote", out)

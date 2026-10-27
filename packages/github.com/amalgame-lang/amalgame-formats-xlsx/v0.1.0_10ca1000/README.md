# amalgame-formats-xlsx

Excel (`.xlsx`) writer for [Amalgame](https://github.com/amalgame-lang/Amalgame) —
pure Amalgame, no template, no external library (the ZIP container is
written with the STORED method, so no zlib either).

```amalgame
import Amalgame.Formats.Xlsx

let wb = new XlsxWorkbook()
let ws: XlsxSheet = wb.AddSheet("Heures")
ws.Text(1, 1, "Projet", Xlsx.Header())
ws.Text(1, 2, "Durée", Xlsx.Header())
ws.Text(2, 1, "IMP-114", Xlsx.Normal())
ws.Duration(2, 2, 27000, Xlsx.Hours())            // 7:30
ws.Formula(3, 2, "SUM(B2:B2)", Xlsx.BoldHours())
ws.SetWidth(1, 30)
ws.FreezeTopRow()
ws.AutoFilter(1, 2, 2)

let bytes: List<int> = wb.Bytes()                  // e.g. HttpResponse.Bytes(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
wb.Save("heures.xlsx")
```

## Surface

| Call | Notes |
|---|---|
| `new XlsxWorkbook()`, `.Creator`, `.AddSheet(name)` | sheet names sanitised (≤ 31 chars, no `:\/?*[]`) |
| `.Bytes()` → `List<int>`, `.Save(path)` → `bool` | the `.xlsx` file |
| `sheet.Text(row, col, value, style)` | inline string, XML-escaped |
| `sheet.Number(row, col, "12.5", style)`, `sheet.Int(...)` | invariant notation (`.` decimal) |
| `sheet.Duration(row, col, seconds, style)` | day fraction; use `Xlsx.Hours()` — `[h]:mm` adds past 24 h |
| `sheet.Date(row, col, y, m, d, style)` | Excel serial; use `Xlsx.Date()` |
| `sheet.Formula(row, col, "SUM(B2:B9)", style)` | computed by Excel / LibreOffice on open |
| `sheet.SetWidth(col, chars)`, `.FreezeTopRow()`, `.AutoFilter(fromCol, toCol, lastRow)` | |
| `Xlsx.Normal() Bold() Hours() Decimal() Date() BoldHours() BoldDecimal() Header() Wrap()` | style ids |
| `Xlsx.ColumnName(27)` → `AA`, `Xlsx.Ref(row, col)`, `Xlsx.DateSerial(y, m, d)`, `Xlsx.DayFraction(s)` | helpers |

Rows and columns are 1-based. Add cells row by row, left to right.

Durations are written as correctly rounded 16-decimal day fractions, so
14:00 is stored exactly as Excel would store it (and shows 14:00, not
13:59:59).

## Tests

```bash
./tests/run_tests.sh [path/to/amc]
```

Builds a two-sheet workbook, checks the ZIP and every XML part with
Python, and — when LibreOffice is installed — converts it to CSV to
check that formulas evaluate (`SUM` over `[h]:mm` = 26:30).

## License

Apache-2.0

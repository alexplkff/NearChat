# Локальный Markdown-трекер

## Wayfinding operations

Карта: [Спецификация локального чата для iOS 26](MAP.md). Её дочерние issues находятся в `issues/`; идентификатор — поле `id`, а имя — поле `title`. Ссылки в обсуждении всегда подписываются именем.

Установка отдельного трекера не требуется. Если понадобится настройка поддерживаемого внешнего трекера, wayfinder предлагает `/setup-matt-pocock-skills`.

Метаданные хранятся во frontmatter. Единственные labels — `wayfinder:*`. `parent` задаёт карту; `status` — `open` или `closed`; `assignee: null` означает отсутствие claim. Claim ставится до работы: `assignee: codex` для ведущего агента или `codex-research-ios` для назначенного исследования. Вопрос содержится в `## Question`; ответ вносится отдельной записью `## Resolution comment` с датой, затем issue закрывается.

Нативных зависимостей у файлов нет, поэтому `blocked_by` — список id других issues. Пустой список означает отсутствие блокеров. Frontier: открытые, неназначенные дочерние issues, у которых все блокеры закрыты. Сначала создаются issues с пустыми списками; связи записываются вторым проходом после появления файлов. Порядок выбора — по имени файла.

По явному запросу пользователя нерешённый билет можно временно отложить: оставить `status: open`, установить `deferred: true` и освободить assignee. Автоматический выбор доступной работы пропускает такие билеты до возобновления пользователем. Их зависимости сохраняются: отложенный билет не считается закрытым и не разблокирует зависимые решения. Это отдельная отметка доступности работы, а не дополнительный label.

Запрос открытых дочерних issues: `rg -l '^status: open$' docs/wayfinder/issues` из корня проекта. Запрос frontier (Python 3, без сторонних библиотек):

```python
from pathlib import Path
import json

rows = []
for path in sorted(Path('docs/wayfinder/issues').glob('*.md')):
    header = path.read_text().split('---', 2)[1]
    fields = dict(line.split(': ', 1) for line in header.strip().splitlines())
    fields['path'] = str(path)
    rows.append(fields)
by_id = {row['id']: row for row in rows}
for row in rows:
    deps = json.loads(row['blocked_by'])
    if (row['parent'] == 'near-chat-map' and row['status'] == 'open'
            and row['assignee'] == 'null'
            and row.get('deferred') != 'true'
            and all(by_id[dep]['status'] == 'closed' for dep in deps)):
        print(f"{row['title']} — {row['path']}")
```

После разрешения билета карта получает только краткую строку со ссылкой. Подробное решение остаётся в issue, исследовательские материалы — в связанном файле `research/`. Подтверждённые требования и глоссарий обновляются ссылками на билет; предложения не становятся требованиями автоматически.

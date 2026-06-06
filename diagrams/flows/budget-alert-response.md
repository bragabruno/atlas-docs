# Budget Alert & Cap Enforcement Flow

Activity flow showing the monthly budget monitoring path: 80% spend threshold triggers an alert for Ops action; 100% cap hit enforces a 429 response for all subsequent requests.

```mermaid
flowchart TB
    SPEND["Ongoing spend accumulation\n(per key, per month — tracked in Redis + PostgreSQL)"]
    CHECK{Spend threshold?}

    UNDER["Normal operation\ncontinue serving requests"]

    ALERT80["80% threshold crossed:\nsend alert to Ops\n(PagerDuty / Slack notification)"]

    subgraph OPS_ACTION["Ops Response Options"]
        OA1["Review usage &\nidentify runaway callers"]
        OA2["Raise monthly budget\n(update key config)"]
        OA3["Throttle or revoke\noffending key"]
        OA1 --- OA2
        OA1 --- OA3
    end

    CAP_HIT["100% budget cap hit:\nhard enforcement active"]
    ALL_REQUESTS["Incoming request\n(POST /v1/chat/completions)"]
    ENFORCE["Gateway: monthly budget check\n→ 429 Budget Exhausted"]
    FE_429["Client receives 429\n(retry-after header)"]

    RESET["Month rolls over:\nspend counter reset\nnormal operation resumes"]

    SPEND --> CHECK
    CHECK -- below 80% --> UNDER
    UNDER --> SPEND
    CHECK -- 80% crossed --> ALERT80
    ALERT80 --> OPS_ACTION
    OPS_ACTION --> SPEND

    CHECK -- 100% cap hit --> CAP_HIT
    CAP_HIT --> ALL_REQUESTS
    ALL_REQUESTS --> ENFORCE
    ENFORCE --> FE_429

    CAP_HIT --> RESET
    RESET --> UNDER
```

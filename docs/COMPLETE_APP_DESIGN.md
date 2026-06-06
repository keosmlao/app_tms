# ODG TMS — ການອອກແບບແອັບຂົນສົ່ງໃຫ້ຄົບ (Complete App Design)

ເອກະສານນີ້ອອກແບບ ODG TMS ໃຫ້ເປັນ **ແອັບຂົນສົ່ງຄົບວົງຈອນ** — ບອກສິ່ງທີ່ມີແລ້ວ (✅),
ບາງສ່ວນ (🟡), ແລະ ອອກແບບ module ທີ່ຍັງຂາດ (❌) ພ້ອມ data model + API + ໜ້າຈໍ + flow.

> ສະຖາປັດຕະຍະກຳ: **Flutter** (`app_tms`) ⇄ **Next.js API** (`tms/src/app/api/mobile`) ⇄ **Postgres** (`odg_tms*`).
> Auth = mobile session (roles + branch scope) · Offline outbox · FCM push · background GPS service.

ຕາຕະລາງຫຼັກ: `odg_tms` (ຖ້ຽວ/job) · `odg_tms_detail` (ບິນ) · `odg_tms_detail_item` (ລາຍການ) ·
`odg_tms_travel_history` (GPS) · `odg_tms_delivery_images`.

---

## 0. ບົດບາດ (Roles) & ແອັບ

| ບົດບາດ | ໃຊ້ຫຍັງ | ໂຟກັສ |
|---|---|---|
| **ຄົນຂັບ (Driver)** | mobile (HomeShell) | ຮັບ→ສົ່ງ→ປິດ ຖ້ຽວ, GPS, ຫຼັກຖານ |
| **ຫົວໜ້າ (Supervisor)** | mobile (SupervisorDashboard) | ຕິດຕາມທີມ, approve, ລາຍງານ |
| **ຜູ້ຈັດການ (Manager)** | mobile (Operations Dashboard) | KPI, ຕິດຕາມທີມ/ລົດ, approve, ບັນຫາການຈັດສົ່ງ |
| **Dispatcher/Admin** | web office (`tms`) | ວາງແຜນ, ສ້າງຖ້ຽວ, ລາຍງານເຕັມ |
| **ລູກຄ້າ (Customer)** | public `/track` | ຕິດຕາມພັດສະດຸ |

---

## 1. Module A — ການຈັດສົ່ງ (Driver core) ✅ ມີຄົບ

ຮັບຖ້ຽວ · ເບີກສາງ · **ຮັບລານລູກຄ້າ** (ຮູບ+ລາຍເຊັນ+GPS) · check-in · ສຳເລັດ (ຮູບ+ລາຍເຊັນ+ຈຳນວນ) ·
ຍົກເລີກ · ແກ້ໄຂ · revert · ປິດງານ (miles+ຮູບ) · QR verify · ໂທ/WhatsApp · ແຜນທີ່ ·
Offline outbox · Push · **GPS background 5ວິ (survive-kill)** · Crashlytics · geofence (dispatch).

**ປັບປຸງເລັກນ້ອຍ:** ໃຫ້ຄົນຂັບເບິ່ງຮູບຮັບເຄື່ອງຄືນ (✅ ເຮັດແລ້ວ) · ປ້າຍສະຖານະ GPS (✅).

---

## 2. Module B — COD / ເກັບເງິນປາຍທາງ ❌ (P0)

**ບັນຫາ:** ດຽວນີ້ບໍ່ມີບ່ອນບັນທຶກເງິນທີ່ຄົນຂັບເກັບຕໍ່ບິນ → reconcile ບໍ່ໄດ້.

**Data model** (`odg_tms_detail`, ຜ່ານ `ensureDeliveryWorkflowSchema`):
```sql
ALTER TABLE odg_tms_detail ADD COLUMN IF NOT EXISTS cod_amount     numeric DEFAULT 0; -- ຍອດທີ່ຕ້ອງເກັບ (ມາຈາກ sale)
ALTER TABLE odg_tms_detail ADD COLUMN IF NOT EXISTS collected_amount numeric;          -- ເກັບໄດ້ຈິງ
ALTER TABLE odg_tms_detail ADD COLUMN IF NOT EXISTS payment_method  varchar;           -- cash | transfer | none
ALTER TABLE odg_tms_detail ADD COLUMN IF NOT EXISTS collected_at    timestamp;
```

**API** (`mobile.js` action + `JobActionSchema` branch):
- `collect_payment` `{ bill_no, amount, method, note }` → set collected_amount/method/collected_at.
- `getBills` ສົ່ງ `cod_amount`, `collected_amount`, `payment_method` ມາ.

**ໜ້າຈໍ (Flutter):**
- ໃນ `_CompPage` (ສຳເລັດ): ເພີ່ມ step **"ເກັບເງິນ"** ສະແດງ `cod_amount`, ປ້ອນ `collected_amount` + ເລືອກ method (ເງິນສົດ/ໂອນ/ບໍ່ເກັບ).
- ໃນ `_CloseJobSheet` (ປິດງານ): ສະຫຼຸບ **ຍອດເກັບລວມ** ຂອງຖ້ຽວ (cash vs transfer).
- Supervisor: metric "ຍອດເກັບມື້ນີ້" + ຕໍ່ຄົນຂັບ.

---

## 3. Module C — ຈັດລຳດັບຈຸດສົ່ງ (Route) + ETA ❌ (P1)

**ບັນຫາ:** ດຽວນີ້ເປີດ map ເທື່ອລະບິນ, ບໍ່ມີລຳດັບ optimal → ຄົນຂັບເລືອກເອງ.

**ວິທີ (2 phase):**
- **P1a — ຈັດລຳດັບ client-side:** nearest-neighbor ຈາກ GPS ຄົນຂັບ → ບິນ pending ທີ່ໃກ້ສຸດກ່ອນ. ໃຊ້ `lat/lng` ທີ່ມີຢູ່ + `Geolocator.distanceBetween`.
- **P1b — EST ເສັ້ນທາງ + ETA:** integrate **OSRM** (open routing) endpoint backend `/api/mobile/route` ສົ່ງ waypoints → ໄດ້ polyline + duration. ETA/ຈຸດ = sum durations.

**ໜ້າຈໍ:** ໜ້າ **"ເສັ້ນທາງ"** ໃນ JobDetail:
- ລາຍການບິນຈັດລຳດັບ (1,2,3…) + ໄລຍະທາງ/ETA ຕໍ່ຈຸດ.
- flutter_map polyline ຜ່ານທຸກຈຸດ.
- ປຸ່ມ "ນຳທາງຈຸດຖັດໄປ" → Google Maps.

**Data:** ບໍ່ຈຳເປັນ column ໃໝ່ (ຄຳນວນ runtime). ຖ້າຢາກ pin ລຳດັບ: `ALTER ... ADD stop_seq int`.

---

## 4. Module D — ສາເຫດສົ່ງບໍ່ສຳເລັດ + ນັດໃໝ່ ❌ (P0)

**ບັນຫາ:** ຍົກເລີກມີແຕ່ comment ເສລີ → ວິເຄາະບໍ່ໄດ້, ບໍ່ມີນັດສົ່ງຄືນ.

**Data model:**
```sql
ALTER TABLE odg_tms_detail ADD COLUMN IF NOT EXISTS cancel_reason_code varchar; -- enum string
ALTER TABLE odg_tms_detail ADD COLUMN IF NOT EXISTS reschedule_date    date;
```

**Reason codes** (ມາດຕະຖານ): `no_one` (ບໍ່ມີຄົນຮັບ) · `refused` (ປະຕິເສດ) · `wrong_addr` (ທີ່ຢູ່ຜິດ) ·
`damaged` (ສິນຄ້າເສຍ) · `not_ready` (ລູກຄ້າຍັງບໍ່ພ້ອມ) · `other`.

**API:** `cancel_bill` ເພີ່ມ `reason_code`; action ໃໝ່ `reschedule_bill` `{ bill_no, new_date, reason_code, note }`
(ບໍ່ປິດບິນ — ຕັ້ງ `reschedule_date`, ຄືນ phase ໃຫ້ waiting ມື້ໃໝ່).

**ໜ້າຈໍ:** `_CancelDialog` → dropdown reason + toggle "ນັດສົ່ງໃໝ່" (date picker). Supervisor: alert ບິນ reschedule.

---

## 5. Module E — ຫົວໜ້າສ້າງ/ມອບໝາຍຖ້ຽວ ❌ (P1)

**ບັນຫາ:** ສ້າງຖ້ຽວໄດ້ແຕ່ web (`jobs/add`). ຫົວໜ້າຢູ່ນອກບໍ່ສ້າງໄດ້.

**API:** mobile endpoint ໃໝ່ `/api/mobile/jobs (POST scope=create)` ຫຼື action `create_job`
(supervisor-gated, reuse office `createJob`/draft logic):
`{ date, driver_id, car, bills:[{bill_no, pickup_transport_code}] }`.
+ `GET ?type=available_bills` (ບິນທີ່ຍັງບໍ່ມອບ, branch-scoped).

**ໜ້າຈໍ:** Supervisor **"ສ້າງຖ້ຽວ"** wizard: ເລືອກວັນ → ຄົນຂັບ+ລົດ → ຄົ້ນ/ເພີ່ມບິນ → ກຳນົດຈຸດຮັບ → ບັນທຶກ.
(reuse pattern ຈາກ office jobs/add.)

---

## 6. Module F — ຫົວໜ້າ: ລາຍງານ/KPI + online/offline + alerts ❌🟡 (P0–P1)

### 6.1 Fleet online/offline 🟡 (P0, ນ້ອຍ)
- `getPhoneFleet` ເພີ່ມ `age_seconds = EXTRACT(EPOCH FROM (NOW() AT TIME ZONE 'Asia/Bangkok' - z.recorded_at))`.
- App: ໝຸດ **ຂຽວ** (≤120ວິ online) / **ເທົາ** (offline) + pulse. label "online/offline".

### 6.2 KPI / ສະຫຼຸບ (P1)
- backend `getSupervisorKpi(session, date)`: ສຳເລັດ%, ກົງເວລາ%, ບິນລວມ, cancel, ຍອດ COD, ຕໍ່ຄົນຂັບ.
- App: card KPI ເທິງ dashboard + "ລາຍງານ" ໜ້າຍ່ອຍ (ມື້/ອາທິດ).

### 6.3 Push alerts ໃຫ້ຫົວໜ້າ (P1)
- FCM topic ຕໍ່ branch. Trigger: ບິນ cancel · ຄົນຂັບ offline >N ນາທີຕອນຖ້ຽວ active · ຈອດດົນ >N · SLA ກາຍ.
- reuse `notifications.js` + `odg_tms_mobile_device`/fcm-token.

---

## 7. Module G — ລູກຄ້າ: ETA ສົດ + feedback ❌ (P2)

- **ETA push/LINE:** ເມື່ອຄົນຂັບເລີ່ມໄປຈຸດນັ້ນ (route module) → notify "ໃກ້ຮອດ ~X ນາທີ" (ມີ `notifyCustomerLine` ຢູ່ແລ້ວ).
- **Feedback:** ຫຼັງ `complete_bill` → public link `/track?rate=billNo` → ດາວ 1–5 + ຄຳເຫັນ. Data: `odg_tms_feedback(bill_no, rating, comment, created_at)`.

---

## 8. Module H — ສົນທະນາ Driver ⇄ Dispatcher ❌ (P2)

- office ມີ chatter/inbox. ເພີ່ມ thread ຕໍ່ຖ້ຽວ: `odg_tms_message(doc_no, sender, body, created_at, read_at)`.
- API: `GET ?type=messages&doc_no=` · action `send_message`. Push ເມື່ອມີຂໍ້ຄວາມ.
- App: ໄອຄອນ chat ໃນ JobDetail → thread.

---

## 9. ສະຫຼຸບ Data model ໃໝ່ (ທັງໝົດຜ່ານ `ensureDeliveryWorkflowSchema`, idempotent)

| ຕາຕະລາງ | column/ໃໝ່ | module |
|---|---|---|
| odg_tms_detail | cod_amount, collected_amount, payment_method, collected_at | B |
| odg_tms_detail | cancel_reason_code, reschedule_date | D |
| odg_tms_detail | stop_seq (option) | C |
| odg_tms_feedback (ໃໝ່) | bill_no, rating, comment, created_at | G |
| odg_tms_message (ໃໝ່) | doc_no, sender, body, created_at, read_at | H |

## 10. ສະຫຼຸບ API ໃໝ່ (`/api/mobile/...`)

| action / endpoint | ບົດບາດ | module |
|---|---|---|
| `collect_payment` | driver | B |
| `reschedule_bill`, `cancel_bill`+reason | driver | D |
| `create_job`, `?type=available_bills` | supervisor | E |
| `?scope=fleet` +age, `getSupervisorKpi` | supervisor | F |
| `?type=route` (OSRM) | driver | C |
| `?type=messages`, `send_message` | both | H |
| feedback (public) | customer | G |

## 11. Roadmap ແບ່ງ phase

| Phase | Module | ເຫດຜົນ |
|---|---|---|
| **P0** (ກະທົບປະຈຳວັນ) | B (COD) · D (reason+reschedule) · F.1 (online/offline) | ໃຊ້ທຸກມື້, ນ້ອຍ, ຄຸ້ມສຸດ |
| **P1** (manager + ປະສິດທິພາບ) | C (route+ETA) · E (ສ້າງຖ້ຽວ) · F.2/F.3 (KPI+alerts) | ເພີ່ມຄຸນຄ່າຫົວໜ້າ + ໄວ |
| **P2** (ລູກຄ້າ + ສື່ສານ) | G (ETA+feedback) · H (chat) | ປະສົບການລູກຄ້າ |

---

## 12. ຫຼັກການອອກແບບ (ໃຫ້ສອດຄ່ອງ codebase ເດີມ)
- Schema: `safeDdl` + `ADD COLUMN IF NOT EXISTS`, bump `__tmsDeliverySchema*_vN`.
- Action ໃໝ່: ເພີ່ມ branch ໃນ `JobActionSchema` (zod) **ສະເໝີ** (ບໍ່ດັ່ງນັ້ນ 400).
- Auth: driver action gate ດ້ວຍ `t.driver = driver_id`; supervisor action gate ດ້ວຍ `canUseSupervisorScope`.
- Offline: action ສຳຄັນໃຊ້ `_postQueueable`; telemetry ໃຊ້ `_post`.
- UI: ນຳໃຊ້ AppTheme, ພາສາລາວ, ຮອງຮັບ offline/cache.

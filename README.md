# MedShare — patient-controlled scan sharing with a kill switch

> Atsign Hackathon 2026. A secure app where a clinic locks a medical scan so
> **only the patient can open it**, the patient **grants a specialist a
> time-limited view**, and the patient can **withdraw that access instantly** —
> live, on screen.

The headline isn't storage. It's **patient-controlled sharing with a kill
switch**: the moment the patient revokes (or the grant expires), the
specialist's view **goes dark**.

---

## Architecture

Two planes, kept deliberately separate — the Atsign thesis:

- **Data plane** — the locked scan. The store holds only encrypted bytes and
  cannot open them.
- **Control plane** — *who may view*. The patient is the only key holder; a
  grant is a key the patient hands to the specialist, and revocation removes it.

The crucial structural insight is **two distinct kinds of "grant"**:

- **Crypto grant** (`Patient → Specialist`): only the patient, as key holder,
  can grant the *ability to open* the scan.
- **Transport/policy grant** (`Patient → Policy Engine`): controls *who may
  fetch* the file. The policy engine holds no keys and cannot make bytes
  readable by itself.

Without the crypto grant, the specialist receives bytes they cannot read. The
full 6-node design (clinic, scan store, patient, policy engine, specialist,
audit log) is the north star; the MVP collapses the store + policy engine into
native sharing (share = grant, delete = revoke).

See [design-reference.md](design-reference.md) for the full design rationale and
the AI Architect blueprint conventions.

---

## How it works on the Atsign Platform

| Concept in the demo | Atsign primitive |
|---|---|
| "Only the patient can read it" | atServers store only encrypted data; the store is blind by design |
| The patient→specialist grant | a **Shared** atKey (`scanref.medshare`) carrying the scan |
| Time-limited view | `ttl` — the grant auto-expires |
| **Revoke → goes dark** | cascade-delete (`ccd`): deleting the shared key removes the recipient's cached copy |
| Specialist re-checks access | each fetch re-reads with cache bypass, so "dark" is a genuine failed read |

The core grant primitive is `SharedKey("scan", specialist, patient)`. Revocation
is cascade-delete of that shared key — stronger than merely blocking future
fetches, because it reaches the cached copy.

---

## Repository layout

| Path | What it is |
|---|---|
| [`headless/`](headless/) | Plain Dart console package — the proven share/read/revoke logic (no Flutter). |
| [`headless/lib/medshare.dart`](headless/lib/medshare.dart) | The single source of truth: `patientShareImage`, `specialistReadImage`, `patientRevoke`, and the `scanKey` grant primitive. |
| [`app/`](app/) | Flutter (Windows desktop) app — the role-toggle UI, built directly on `medshare`. |
| [`design-reference.md`](design-reference.md) | Canonical design decisions, philosophy, and limitations. |

The Flutter app and the console tools share **one verified code path** — the UI
is a thin shell over the headless logic that was proven first.

---

## Running it

**Prerequisites:** Flutter 3.35 / Dart 3.9, two onboarded atSigns with their
`.atKeys` in `~/.atsign/keys/`, and (for the desktop app) Visual Studio 2022
with the "Desktop development with C++" workload.

### Headless (prove the loop in the console)

```bash
cd headless
dart pub get
dart run bin/share.dart    # patient shares the scan with the specialist
dart run bin/read.dart     # specialist reads it
dart run bin/revoke.dart   # patient revokes
dart run bin/read.dart     # specialist read is now DARK
```

### The app

```bash
cd app
flutter pub get
flutter run -d windows
```

---

## Honest limitations

- **Revocation ≠ clawing back exfiltrated plaintext.** Cascade-delete removes
  the *cached* copy; a locally saved decrypted image can't be retracted. "Goes
  dark" holds because the specialist app re-fetches each view and caches no
  plaintext.
- **Metadata leakage.** Who-shared-with-whom-and-when is visible even when the
  contents aren't.
- **Onboarding / break-glass.** The demo assumes provisioned atSigns; pure
  end-to-end encryption means lost-key and unconscious-patient cases need a v2
  break-glass delegate.
- **Framing:** this is a **prototype demonstrating the security model**, not a
  HIPAA/PHIPA-certified product. This architecture makes compliance *easier*.
---
# paygrid

A production-grade payments backend built with Go and microservices.

## Overview

paygrid is a set of Go microservices for handling payments, transactions, and related financial operations.

**Key features**

- **Double-entry ledger** in PostgreSQL: every transaction must balance, and the ledger is append-only
- **gRPC** for fast, typed communication between services
- **Event-driven architecture** using NATS JetStream
- **Kubernetes** deployment

## Tech Stack

| Area | Technology |
| --- | --- |
| Language | Go |
| Database | PostgreSQL |
| Service communication | gRPC |
| Messaging | NATS JetStream |
| Deployment | Kubernetes |

## How the Ledger Works

- **Accounts** hold a single currency and have a normal balance side (debit or credit).
- **Transactions** group a set of entries together.
- **Entries** are individual debit or credit lines, stored as integer minor units (e.g. kobo or cents).
- A database trigger checks at commit time that, for each currency, total debits equal total credits.
- Ledger rows can't be updated or deleted. Mistakes are fixed by posting a reversing transaction.
- The `account_balances` view calculates each account's current balance.

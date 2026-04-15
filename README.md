# Storage Unit Sweepstakes

Storage Unit Sweepstakes is a hackathon-ready raffle system built on top of the EVE Frontier `world-contracts` ecosystem. It combines Move smart contracts, a React web app, and lightweight deployment tooling into a focused standalone project that is easy to demo, review, and submit.

## Deployment Information

- **Project Name:** Storage Unit Sweepstakes
- **DeepSurge Project Page:** [https://www.deepsurge.xyz/projects/7fe957f3-0e64-479f-86a9-ded4cf18b596](https://www.deepsurge.xyz/projects/7fe957f3-0e64-479f-86a9-ded4cf18b596)

### Stillness Deployment

- **Extension Package:** `0x378c592b9b78b98d8b4295cdf2dd852078d5ad6fcb05451373256af066f35fe0`
- **Storage Unit Assembly ID:** `0x12eb62a2e89fabd6178de55c2795c8abb656270ce15a2457f026eaf88cdd046d`

### Utopia Deployment

- **Extension Package:** `0x778eecc126100414f42f8f5c7493807a0a2bd136da7939f839d55831d8c606bd`
- **Storage Unit Assembly ID:** `0x90f032a03c95beaeb8c421b7e82178c764f3cdda78fcef1a245245e54e7cb5f1`


## Overview

This project turns on-chain assets into prizes for a transparent, verifiable lottery flow.

A typical game works like this:

1. A creator locks a prize from their `StorageUnit`.
2. The protocol creates an on-chain `LotteryGame` object.
3. Players buy tickets using `EVE`.
4. Once all tickets are sold, a winner is drawn using Sui's on-chain randomness via `RandomGenerator`.
5. Ticket proceeds are settled to the creator.
6. The winner claims the prize into their owned inventory under the same `StorageUnit`.
7. If the game is canceled before sellout, buyers are refunded and the prize is returned.

## Why this project stands out

- Fully on-chain raffle lifecycle, from prize locking to settlement
- Verifiable winner selection powered by Sui randomness
- Real asset custody through `StorageUnit` integration
- End-to-end product demo with both contracts and frontend included
- Wallet-connected UX with automatic resource discovery for supported users

## What's included

### Smart contracts

- `contracts/sweepstakes_ext`
  - Core Move package for the raffle system
- `contracts/world`
  - Local Move dependency required by the extension package
- `contracts/assets`
  - Local Move package that provides the `EVE` coin type

`world` and `assets` are included so `sweepstakes_ext` remains buildable and deployable as a standalone project.

### Frontend

- `web/sweepstakes`
  - Independent React + Vite application
  - Supports wallet connection, raffle creation, ticket purchases, drawing winners, claiming prizes, and game cancellation

### Tooling

- `scripts/deploy-sweepstakes-ext.sh`
- `scripts/deploy-standalone-ext.sh`
- `scripts/lib.sh`
- `ts-scripts/utils/extract-json.ts`

These scripts provide the minimum tooling needed to publish the contract and extract deployment results.

## Repository structure

```text
.
├─ contracts/
│  ├─ assets/
│  ├─ world/
│  └─ sweepstakes_ext/
├─ scripts/
├─ ts-scripts/
│  └─ utils/
└─ web/
   └─ sweepstakes/
```

## Product flow

### Create a raffle

To create a game, the creator needs:

- A usable `Character`
- A usable `StorageUnit`
- A prize already deposited in that `StorageUnit`
- Extension authorization enabled for the target `StorageUnit`

When a raffle is created, the contract withdraws the prize from the `StorageUnit` and locks it inside the on-chain `LotteryGame` object.

For supported users, the frontend auto-detects and pre-fills the required on-chain resources after wallet connection, reducing manual setup.

### Buy tickets

Players can purchase one or more tickets using `EVE`.

After a successful purchase:

- `sold_tickets` increases
- `sale_proceeds` accumulates
- The purchased tickets become eligible for the final draw

### Draw the winner

Once `sold_tickets == total_tickets`, the creator can call `draw_winner`.

After the draw:

- The winner address is recorded on-chain
- The winner's character ID is recorded
- The winning ticket number is recorded
- Ticket revenue is settled to the creator

### Claim the prize

The winner calls `claim_prize` to receive the locked prize into their owned inventory under the target `StorageUnit`.

### Cancel the raffle

If the raffle has not sold out yet, the creator can call `cancel_game` to:

- Refund all ticket buyers
- Return the prize to the creator
- Mark the game as canceled

## Key contract files

- `contracts/sweepstakes_ext/sources/sweepstakes.move`
  - Main compilable contract source
- `contracts/sweepstakes_ext/reference/sweepstakes.move`
  - Annotated Chinese reference version
- `contracts/sweepstakes_ext/reference/sweepstakes_nocomment.move`
  - Clean reference version without annotations

## Build the contract

```bash
cd contracts/sweepstakes_ext
sui move build
```

## Deploy the contract

A minimal deployment flow is included at the repository root.

### 1. Prepare environment variables

```bash
cp .env.example .env
```

Then fill in:

- `SUI_NETWORK`
- `WORLD_PACKAGE_ID`
- `ASSETS_PACKAGE_ID`

Example:

```env
SUI_NETWORK=testnet
WORLD_PACKAGE_ID=
ASSETS_PACKAGE_ID=0xf0446b93345c1118f21239d7ac58fb82d005219b2016e100f074e4d17162a465
```

### 2. Install root dependencies

```bash
npm install
```

### 3. Publish the sweepstakes package

```bash
npm run deploy:sweepstakes-ext
```

Deployment output is written to:

- `deployments/<network>/`

## Frontend

The web application lives in `web/sweepstakes` and talks directly to the deployed contract through Sui RPC.

## Frontend environment variables

Create a local frontend env file:

```bash
cd web/sweepstakes
cp .env.example .env
```

Then configure:

- `VITE_SWEEPSTAKES_PACKAGE_ID`
- `VITE_WORLD_PACKAGE_ID`
- `VITE_EVE_TYPE`

Example:

```env
VITE_SWEEPSTAKES_PACKAGE_ID=0xYOUR_SWEEPSTAKES_PACKAGE_ID
VITE_WORLD_PACKAGE_ID=0xYOUR_WORLD_PACKAGE_ID
VITE_EVE_TYPE=0xYOUR_DEPLOYED_EVE_TOKEN_PACKAGE
```

## Run the frontend

```bash
cd web/sweepstakes
npm install
npm run dev
```

## Frontend capabilities

- Wallet connection
- Sweepstakes package, world package, and EVE type configuration
- Automatic discovery of `Character`, `StorageUnit`, and `OwnerCap`
- Reading active raffles from on-chain data
- Creating raffles
- Buying tickets
- Drawing winners
- Claiming prizes
- Canceling raffles

## Tech stack

- Move
- Sui
- React
- Vite
- EVE Frontier `world-contracts`

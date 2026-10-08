# Spatial protocol (Foundry)

Spatial lets holders of Robinhood Stock Tokens raise USDG on fixed terms from other people, wallet to wallet.
Lenders publish EIP-712 signed offers stating a rate, a size and an LTV ceiling. A borrower picks one or more of
those offers, and CreditHub (the hub) originates a single syndicated loan from them, locking the stock tokens
as overcollateral and minting each participating lender an ERC-721 slice note for their portion. Positions that
become unsafe are sold off in a descending-price auction; loans nearing maturity can be refinanced through a
rising-rate one.

This folder holds the Solidity source, tests and deployment scripts. Product information lives at
[onspatial.org](https://onspatial.org) and the full documentation at
[docs.onspatial.org](https://docs.onspatial.org).

## Quick facts

| | |
| --- | --- |
| Networks | Robinhood Chain mainnet (chain id 4663) and its testnet (chain id 46630), both Arbitrum Nitro |
| Loan currency | USDG |
| Collateral | Robinhood Stock Tokens, priced through Chainlink |
| Compiler | solc 0.8.26, `via_ir`, optimizer on at 100 runs, EVM target `cancun` |
| Packages | forge-std 1.9.7 and OpenZeppelin Contracts 5.2.0, both pinned in `soldeer.lock` |
| Tests | 139 across 9 suites |

## Repository tour

```
src/
  CreditHub.sol             the hub; owns loans, slices, escrow and the hooks used by both auctions
  QuoteBook.sol             abstract parent of the hub: EIP-712 domain, nonce bitmaps, per-digest fill totals
  LiquidationAuction.sol    descending-price sale of collateral from unhealthy loans
  RolloverMarket.sol        rising-rate refinancing of a loan into a fresh term
  OracleGuard.sol           the guard; prices collateral and flags whether each quote can be trusted
  PermissionRegistry.sol    role checks, forwarded to the credential adapter the risk config names
  RiskConfig.sol            the risk config; every parameter, the timelock, the owner and the guardian
  SliceNote.sol             "Spatial Slice Note" (SPSN), one ERC-721 per lender slice
  ReserveAdapter.sol        parks waiting lender USDG in one approved ERC-4626 vault
  FeeVault.sol              where protocol income accumulates
  adapters/
    CredentialRegistry.sol  default credential source, written to by approved issuers
  interfaces/               ICreditHub, IOracleGuard, IPermissionRegistry (with IAccessAdapter), IReserveAdapter,
                            IRiskConfig, ISliceNote, and IExternal for third-party surfaces
  libraries/
    LoanTypes.sol           enums, offer flags, units and structs, plus the Permissions role ids
    QuoteHash.sol           typed-data hashes for LendOffer and BorrowRequest
    InterestMath.sol        simple per-second interest on a slice
  mocks/Mocks.sol           test doubles for third-party contracts
script/                     Deploy, DeployCore and six seeding scripts (see below)
test/                       Base fixture plus nine suites
deployments/                address books written by the deploy scripts
foundry.toml, soldeer.lock  build profile, RPC and explorer aliases, pinned packages
.env.example                every variable the scripts understand
```

## The contracts, one by one

**CreditHub.** The centre of the system, holding every loan for its whole life. On origination it checks the
borrower's request and each lender's signature, takes the collateral into escrow, pulls principal from each
lender (or from the reserve adapter) to the borrower, and records the loan with its slices. It then accepts
repayments and collateral top-ups, and exposes restricted hooks that only the liquidation auction and the
rollover market may call. It has no owner and no proxy. Governance can touch it exactly once, through `wire`,
which fixes the auction, rollover and reserve addresses for good. Every parameter is read fresh from the risk
config at the moment it is needed.

**QuoteBook.** Inherited by the hub. It builds the EIP-712 domain by hand (name `Spatial`, version `1`, chain
id, hub address) to save bytecode, keeps a cancellation bitmap per maker, and counts how much principal each
offer digest has already supplied. A nonce here is a cancellation handle, not a sequence number: filling an
offer does not consume it, and one nonce can be shared by many offers so they can all be withdrawn together. A
standing offer keeps funding loans until its `principalMax` is used up. Signatures go through OpenZeppelin's
SignatureChecker, so both ordinary keys and EIP-1271 contract wallets work.

**QuoteHash.** Struct hashing for `LendOffer` and `BorrowRequest`, plus the key that ties an offer to the
rollover of one particular loan.

**LiquidationAuction.** Sells escrowed collateral at a price that starts at the guard's quote plus a premium
and falls in a straight line to a floor. It stops once buyers have covered the debt plus the penalty, or when
the collateral runs out. Before bidding opens, lenders who asked for in-kind settlement receive collateral at
the quoted price, and if the market is closed, slices whose lenders opted out of closed-market sales are spun
off into a new loan that carries on as before. Buyer payments go straight to the hub, which pays out on
`finalizeLiquidation`.

**RolloverMarket.** Lets a borrower refinance an Active loan before it matures. The offered rate begins at the
loan's blended APR and rises linearly until it hits that APR plus the spread cap. New lenders join with signed
offers at or below the current rate and their USDG is taken immediately. Once enough is raised to cover the
debt and the rollover fee, old lenders are paid off and the new ones get slices on a fresh term. If time runs
out first, anyone can fail the auction: new lenders are refunded and the loan becomes Defaulted. The borrower
may also withdraw at any point before clearing. Rate discovery uses no oracle, though LTV checks still do.

**OracleGuard.** The only component allowed to value collateral. For each token it reads a Chainlink Data Feed,
and optionally a Data Streams adapter, and returns a quote together with flags covering the trading session,
staleness against that session's allowance, a pricing halt, the ERC-8056 multiplier (reported, never applied,
because Chainlink equity feeds already include it), a cap on sharp price moves, and L2 sequencer recovery.
`quote` does not revert on bad conditions; callers read the flags. Each collateral token is tied to the loan
token its feed is quoted in.

**PermissionRegistry and Permissions.** The registry answers "may this address borrow, lend, liquidate, relay
or hold a slice note?" by forwarding to whichever adapter the risk config points at, so the credential source
(EAS, ONCHAINID, Chainlink ACE or the bundled registry) can change without consumers moving. The `Permissions`
library in `LoanTypes.sol` defines the five role ids: `BORROWER`, `LENDER_PROFESSIONAL`, `LENDER_RETAIL`,
`LIQUIDATOR` and `RELAYER`.

**CredentialRegistry.** A small EAS-style store for chains without EAS. Each record links an account and role
to a jurisdiction code, an investor class and an expiry, with no personal data on chain. Only issuers approved
in the risk config can write or revoke.

**SliceNote.** The ERC-721 "Spatial Slice Note" (symbol SPSN). Token id equals slice id. Only the hub can mint
or burn, and a transfer succeeds only if the recipient passes the lender check, after which the hub sends
future payments to the new holder. The hub address is set once through `setDesk`.

**ReserveAdapter.** Holds unmatched lender USDG in one whitelisted ERC-4626 vault (the Morpho vault on Robinhood
Chain), tracking each lender's shares, and hands funds to the hub when an offer with `FLAG_PARK_IDLE` is
filled; repayments to such slices are deposited back. Vault approval is checked on every deposit, so delisting a
vault halts new deposits while withdrawals keep working. Its hub is also set once through `setDesk`.

**RiskConfig.** Owns every tunable: tiers, enabled tokens, terms, fees, auction settings, exposure caps,
credential issuers and halts. Changes are queued with `schedule(calls, salt, rationale)`, become executable
after `delay`, and must be run with `execute(calls, salt)` inside a grace window. Until `finishBootstrap()` is
called the owner may hit setters directly; afterwards only the timelock can. Ownership moves in two steps
(`transferOwnership`, then `acceptOwnership`). The guardian may call `setPaused` to stop new loans,
liquidations or both, but can only switch halts on; lifting them is for the owner or the timelock.

**FeeVault.** Receives origination fees, the interest share, rollover fees and the protocol's cut of liquidation
penalties as plain transfers. Only the risk config's owner can withdraw.

**LoanTypes, InterestMath, IExternal, mocks.** `LoanTypes` is the shared vocabulary (sides, sessions, loan
states, offer flags, units, structs). `InterestMath` accrues simple interest per second on principal only, with
one rounding step. `IExternal` holds the trimmed third-party interfaces: Chainlink aggregator, ERC-8056
multiplier, oracle pause source, market status source and stream adapter. `Mocks.sol` provides `MockERC20`,
`MockStockToken` (which also acts as its own multiplier, pause and session source), `MockAggregatorV3`,
`MockVault4626` and `MockStreamAdapter`.

## Getting set up

You need Foundry. Packages arrive through soldeer, not git submodules, and are unpacked into `dependencies/`
(which is git-ignored):

```bash
forge soldeer install
```

Remappings are declared by hand in `foundry.toml` and soldeer is told not to regenerate them.

## Compiling and running the suite

```bash
forge build
forge test          # add -vv or -vvv for traces
```

A clean run reports 139 passing tests in 9 suites:

| Suite | Tests | Focus |
| --- | --- | --- |
| `Origination.t.sol` | 22 | multi-lender fills, fees, rejected offer sets, relayed and replayed requests, reserve funding, slice transfers |
| `Repayment.t.sol` | 9 | per-slice interest, minimum period, partial and full payoff, third-party payers, grace, repaying while paused or after a failed rollover |
| `LiquidationAuction.t.sol` | 29 | opening conditions, price curve, proceeds and penalty split, restarts, closed-market floors and opt-outs, in-kind payment |
| `RolloverMarket.t.sol` | 16 | who may start, rate climb, clearing, expiry into default, withdrawal, interruption by liquidation |
| `OracleGuard.t.sol` | 21 | feed settings, sequencer checks, Data Streams reports, refused prices |
| `RiskConfig.t.sol` | 29 | timelock, guardian limits, setter validation, credentials, slice note transfers, fee vault, `wire` |
| `Reserve.t.sol` | 9 | share accounting, full exits, isolation between lenders, hub-only movements |
| `Invariants.t.sol` | 3 + 1 | fuzzed and invariant checks on ledger totals |

`test/Base.t.sol` is the common fixture. It deploys the whole system over mocks, applies the production
parameter set, credentials a borrower, three professional lenders and a liquidator, and funds them.

## Watching the bytecode budget

EIP-170 caps runtime code at 24,576 bytes. CreditHub currently compiles to 24,451, a margin of just 125 bytes.
Check it whenever the hub or `QuoteBook` changes:

```bash
forge build --sizes
```

The optimizer settings (`via_ir = true`, `optimizer_runs = 100`) are part of what keeps it under. If the hub
ever goes over, a deploy would only succeed with `--code-size-limit 1000000`, or `--disable-code-size-limit`
against a local Anvil fork. Take that as a sign the hub needs trimming rather than a setting to keep.

## Putting it on chain

### Environment

Start from `.env.example`, saved as `.env` (git-ignored). The variables:

| Variable | Used by | Meaning |
| --- | --- | --- |
| `PRIVATE_KEY` | all scripts | deploying wallet; also initial owner and, by default, guardian and credential issuer |
| `ROBINHOOD_TESTNET_RPC`, `ROBINHOOD_RPC` | `foundry.toml` | endpoints behind the `robinhood_testnet` and `robinhood` aliases; official URLs are listed at docs.robinhood.com/chain |
| `ROBINHOOD_TESTNET_BLOCKSCOUT_API`, `ROBINHOOD_BLOCKSCOUT_API`, `BLOCKSCOUT_API_KEY` | `foundry.toml` | Blockscout verification endpoints (the key can stay `unused`) |
| `GOV` | Deploy | eventual risk config owner; it must call `acceptOwnership()` afterwards |
| `GUARDIAN` | Deploy | pause key, defaults to the deployer |
| `TIMELOCK_DELAY` | Deploy, DeployCore | delay in seconds, 3600 if unset |
| `FINISH_BOOTSTRAP` | Deploy | `true` ends bootstrap so that later changes need the timelock |
| `DEPLOY_MOCKS` | Deploy | allows mocks for any missing external address; on by default except on chain 4663 |
| `ATTESTATION_ISSUER` | Deploy | credential issuer, defaults to the deployer |
| `USDG`, `VAULT`, `STOCK_TOKEN` and its `STOCK_FEED` | Deploy | live token, Chainlink feed and ERC-4626 vault; mocked when blank and mocks are allowed |
| `SEQUENCER_FEED` | Deploy | Chainlink L2 uptime feed, skipped if blank |
| `MARKET_STATUS_SOURCE` | Deploy | session source for the guard when mocks are off; blank means its built-in weekly timetable |
| `STREAM_ADAPTER` | Deploy | Data Streams adapter; blank means Data Feeds only |
| `STALENESS_REGULAR`, `STALENESS_EXTENDED`, `STALENESS_CLOSED` | Deploy | maximum price age per session, defaults 3600, 7200 and 345600 seconds |
| `MOVE_CAP_WINDOW` | Deploy | checkpoint window for the 25 percent move cap, default 3600 seconds |

### Full deployment

`script/Deploy.s.sol` creates every contract, writes the opening risk settings while bootstrap is still open,
registers the collateral feed with the guard, points the slice note and reserve adapter at the hub with
`setDesk`, calls `wire`, and saves the address book. When mocks are in use and the deployer is the issuer, it
also credentials the deployer as borrower, professional lender, liquidator and relayer so the seed scripts
work without further setup. If `GOV` differs from the deployer, ownership is offered to it at the end.

```bash
source .env
forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast --verify \
  --gas-estimate-multiplier 200 --slow
```

### Core-only deployment

`script/DeployCore.s.sol` is a lighter option for testnets and local nodes, and refuses to run on chain 4663.
It brings up RiskConfig, PermissionRegistry, CredentialRegistry, OracleGuard, SliceNote, CreditHub and
LiquidationAuction over mock USDG, one mock stock token and its mock feed. RolloverMarket, ReserveAdapter,
FeeVault and the vault are skipped, fees go to the deployer, and the deployer is credentialed as borrower,
professional lender and liquidator. It reads only `PRIVATE_KEY` and `TIMELOCK_DELAY`.

```bash
forge script script/DeployCore.s.sol --rpc-url robinhood_testnet --broadcast
```

### Seeding sample activity

All seed scripts read addresses from the deployment file for the current chain and expect mocks.

| Script | Runs on | What it does |
| --- | --- | --- |
| `Seed.s.sol` | full | two loans (one single-lender, one in two slices), a top-up, partial and full repayment, a reserve deposit, a nonce cancellation |
| `SeedDeep.s.sol` | full, after `Seed` | relayed origination, a loan funded from the reserve, a 90 day loan, a third-party repayment, a slice sale, a withdrawn request, guardian pause, one timelock change queued and one cancelled, and a pair of liquidations, one in open hours and one with the market shut that splits off an opted-out lender and pays another in collateral |
| `SeedExecute.s.sol` | full, after `SeedDeep` | executes the queued change, which doubles the exposure cap and restores a one hour delay |
| `SeedCore.s.sol` | core | four loans, top-up, repayments, a price drop and a single-purchase liquidation, a nonce cancellation |
| `SeedMore.s.sol` | core, after `SeedCore` | three extra wallets, a three-slice loan, a slice transfer, pause and unpause, the 90 day term enabled, a liquidation cleared in three buys |
| `SeedResume.s.sol` | core | finishes a `SeedCore` run that stopped just after its auction opened |

`SeedDeep` shortens the timelock to one minute so its queued change can be carried out soon after. Wait about
that long before starting `SeedExecute`:

```bash
forge script script/SeedDeep.s.sol --rpc-url robinhood_testnet --broadcast --gas-estimate-multiplier 200 --slow
forge script script/SeedExecute.s.sol --rpc-url robinhood_testnet --broadcast --gas-estimate-multiplier 200 --slow
```

The extra wallets in `SeedDeep` and `SeedMore` use keys derived from fixed public strings. They are fine for
testnet and nowhere else.

### Robinhood Chain notes

- **Gas.** L1 calldata is charged on top as extra gas, which means forge underestimates what the bigger
  calls need. Doubling the estimate and sending transactions one by one (`--gas-estimate-multiplier 200
  --slow`) avoids that.
- **Verification.** The explorer is Blockscout, not Etherscan. Add the verifier flags shown below to the
  deploy command, or verify later by repeating that command with the same flags and the resume options:

  ```bash
  --verify --verifier blockscout --verifier-url https://explorer.testnet.chain.robinhood.com/api/
  --broadcast --resume --private-key $PRIVATE_KEY
  ```
- **Handover.** With `GOV` set, the multisig takes control only after it calls `acceptOwnership()` on the risk
  config. With `FINISH_BOOTSTRAP=true`, direct setter access ends and all further changes go through
  `schedule` and `execute`.

## Live testnet deployment

The current full deployment on Robinhood Chain testnet (chain id 46630) went out on 11 October 2026 from the
wallet `0x256Ed5953190207Fc5B788a4c4924ccF4d24f673`, which is also the risk config owner, guardian and
credential issuer. Bootstrap is still open and the timelock delay is 3600 seconds. USDG, the stock token, its
feed and the vault are mocks. Explorer: [explorer.testnet.chain.robinhood.com](https://explorer.testnet.chain.robinhood.com).

| Contract | Address |
| --- | --- |
| CreditHub | [`0xB56AF6a508550f8bcd2D038F482742e550b4f4bc`](https://explorer.testnet.chain.robinhood.com/address/0xB56AF6a508550f8bcd2D038F482742e550b4f4bc) |
| LiquidationAuction | [`0xe98DCB27Ce26dD298380Ff9Cd3BA2A1614e2AA8d`](https://explorer.testnet.chain.robinhood.com/address/0xe98DCB27Ce26dD298380Ff9Cd3BA2A1614e2AA8d) |
| RolloverMarket | [`0x8dD5a92Fe3A0E9768F11Ea0E21a0Dc08D8Fc21B9`](https://explorer.testnet.chain.robinhood.com/address/0x8dD5a92Fe3A0E9768F11Ea0E21a0Dc08D8Fc21B9) |
| OracleGuard | [`0xAb2B95b767FB60c91aaA8Dfa051D2c7cb373d04E`](https://explorer.testnet.chain.robinhood.com/address/0xAb2B95b767FB60c91aaA8Dfa051D2c7cb373d04E) |
| RiskConfig | [`0xA43124EEf26941BC774e038dCCEeeb9e8D234c91`](https://explorer.testnet.chain.robinhood.com/address/0xA43124EEf26941BC774e038dCCEeeb9e8D234c91) |
| PermissionRegistry | [`0x4Bb6f4a22ec8E1b4EC9d2A0EAB8F14cE671153DB`](https://explorer.testnet.chain.robinhood.com/address/0x4Bb6f4a22ec8E1b4EC9d2A0EAB8F14cE671153DB) |
| CredentialRegistry | [`0xe2675E1610192dC84E8411De820D61A15C06Dc12`](https://explorer.testnet.chain.robinhood.com/address/0xe2675E1610192dC84E8411De820D61A15C06Dc12) |
| SliceNote | [`0xe688445192108245C7D5E68D3E101d47e050A987`](https://explorer.testnet.chain.robinhood.com/address/0xe688445192108245C7D5E68D3E101d47e050A987) |
| ReserveAdapter | [`0xAc5302ba4689a8cF138987574d2F677515025222`](https://explorer.testnet.chain.robinhood.com/address/0xAc5302ba4689a8cF138987574d2F677515025222) |
| FeeVault | [`0x97b4d50797567114b148Ce58a3387dEa40A70c0B`](https://explorer.testnet.chain.robinhood.com/address/0x97b4d50797567114b148Ce58a3387dEa40A70c0B) |
| USDG (mock) | [`0x6C1Ba1427C36cf79A42EfE74DC414EB81758A6a4`](https://explorer.testnet.chain.robinhood.com/address/0x6C1Ba1427C36cf79A42EfE74DC414EB81758A6a4) |
| StockToken (mock NVDAx) | [`0x19A57976365Ddf454dD0604E4eDbE0603B4416d0`](https://explorer.testnet.chain.robinhood.com/address/0x19A57976365Ddf454dD0604E4eDbE0603B4416d0) |
| StockFeed (mock) | [`0xD09fA76090e9991B268900eb1dD9cE6F48b8883a`](https://explorer.testnet.chain.robinhood.com/address/0xD09fA76090e9991B268900eb1dD9cE6F48b8883a) |
| Vault (mock ERC-4626) | [`0xcfb5739058B3db47DE2C23ACD239E9666fb2AcAd`](https://explorer.testnet.chain.robinhood.com/address/0xcfb5739058B3db47DE2C23ACD239E9666fb2AcAd) |

The same addresses are in `deployments/46630.json`, which is what the scripts and the web platform read. All
14 contracts are verified on Blockscout.

The deployment has been seeded with `Seed`, `SeedDeep` and `SeedExecute` (93 transactions including the
deploy), so it now holds 9 loans and 12 slice notes. Two loans were settled through liquidation auctions, one
in open hours and one with the market closed, and loan 8 was split out of the closed-market one and is still
Active. The queued timelock change has been executed, raising the stock token's exposure cap to 2,000,000 USDG
and putting the delay back at 3600 seconds. Neither pause flag is set.

## Deployment records

Both deploy scripts write `deployments/<chainId>.json`, keyed by contract name, with a `chainId` field. The
seed scripts and the web platform read from it. Keys are `CreditHub`, `LiquidationAuction`, `RolloverMarket`,
`OracleGuard`, `PermissionRegistry`, `CredentialRegistry`, `SliceNote`, `ReserveAdapter`, `RiskConfig`,
`FeeVault`, `USDG`, `StockToken`, `StockFeed` and `Vault`. A core-only deployment uses the same keys and
records the zero address for whatever it skipped.

Present in the folder:

| File | Contents |
| --- | --- |
| `46630.json` | current testnet address book (full deployment of 2026-10-11, listed above) |
| `46630.full-2026-09-24.json` | earlier full testnet deployment |
| `46630.full-2026-09-11.json` | earlier full testnet deployment |
| `46630.full-2026-08-29.json` | earlier full testnet deployment |
| `46630.core-2026-09-04.json` | earlier core-only testnet deployment |

The dated files are kept for reference; scripts only ever read the undated one, and running a deploy
overwrites it.

## Design guarantees

- **Atomic origination.** A loan is created only when every offer checks out, every lender's principal is
  received and the collateral is escrowed in the same transaction. Any failure reverts the lot.
- **Repayment cannot be switched off.** Borrowers can repay while a loan is Active (including the grace period
  after maturity) and while it is Defaulted after a failed rollover. Only the start of a liquidation auction or
  the loan closing ends that. No pause flag and no risk config setting blocks repayment, adding collateral or
  getting collateral back after payoff.
- **Losses stay local.** Each slice bears its own shortfall; nothing is pooled across slices or loans.
- **One price source.** Collateral is valued only through the guard, using the feed configured for that exact
  collateral token.
- **Fixed payout order.** Auction proceeds are applied in this sequence: keeper's cut, lender claims, lenders'
  penalty portion, protocol's penalty portion, and finally any surplus to the borrower. Unsold collateral
  goes back to the borrower too.
- **No upgrade path.** The hub, `QuoteBook`, SliceNote, LiquidationAuction and RolloverMarket have no proxy
  and no admin. Changing them means deploying again.
- **Governance cannot take funds.** No governance key can move escrowed collateral, lender principal or
  reserve vault balances.

## Reporting a vulnerability

Please email security@onspatial.org privately and do not open a public issue. How the code is tested,
audited and operated, and how disclosures are handled, is covered in `docs/architecture/assurance.md`.

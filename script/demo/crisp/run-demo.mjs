#!/usr/bin/env node
// End-to-end demo: an Octant CrispAllocationMechanism round on a local Interfold/CRISP stack.
//
// Deploys the mechanism on the CRISP dev chain, signs up three voters, opens a CRISP round,
// casts real encrypted ballots through the CRISP SDK and server (including a re-vote), waits for
// the ciphernode committee to decrypt the tally, then finalizes, queues and redeems in Octant.
//
// Prerequisites: see README.md next to this file.

import { existsSync, readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const OCTANT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../../..')
const INTERFOLD_DIR = resolve(process.env.INTERFOLD_DIR ?? join(OCTANT_ROOT, '../interfold'))
const CRISP_DIR = join(INTERFOLD_DIR, 'examples/CRISP')
const SDK_DIR = join(CRISP_DIR, 'packages/crisp-sdk')
const RPC_URL = process.env.RPC_URL ?? 'http://127.0.0.1:8545'
const CRISP_SERVER_URL = process.env.CRISP_SERVER_URL ?? 'http://127.0.0.1:4000'
const CHAIN_ID = 31337

// insecure-512 (param set 0) circuit configuration, as pinned in crates/evm-helpers/src/contracts.rs
const CRYPTO_CONFIG_ID_PARAM_SET_0 = '0x7d3f52af7ad13baa9f34ce2426e980907ffeb86b4b374308e6c590d5d43f9e41'

// --- dependencies resolved from the Interfold checkout -----------------------------------------
const sdkRequire = createRequire(join(SDK_DIR, 'package.json'))
const importFrom = (specifier) => import(pathToFileURL(sdkRequire.resolve(specifier)).href)
const viem = await importFrom('viem')
const { privateKeyToAccount } = await importFrom('viem/accounts')
const sdk = await import(pathToFileURL(join(SDK_DIR, 'dist/index.js')).href)
const { loadCircuits } = await import(pathToFileURL(join(SDK_DIR, 'dist/presets/insecure-512.js')).href)
const { createPublicClient, createWalletClient, createTestClient, http, parseAbi, keccak256, toHex, formatUnits, parseUnits, parseEventLogs } = viem

// --- helpers -----------------------------------------------------------------------------------
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const t0 = Date.now()
const log = (msg) => console.log(`[${((Date.now() - t0) / 1000).toFixed(0).padStart(4)}s] ${msg}`)
const step = (msg) => console.log(`\n=== ${msg}`)
const tokens = (v) => formatUnits(v, 18)

async function waitFor(what, fn, { timeoutMs = 600_000, intervalMs = 2_000 } = {}) {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    const value = await fn()
    if (value) return value
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`)
    await sleep(intervalMs)
  }
}

function artifact(source, name) {
  const path = join(OCTANT_ROOT, 'out', source, `${name}.json`)
  if (!existsSync(path)) throw new Error(`missing ${path}; run \`forge build\` in ${OCTANT_ROOT}`)
  const json = JSON.parse(readFileSync(path, 'utf8'))
  return { abi: json.abi, bytecode: json.bytecode.object }
}

const chain = {
  id: CHAIN_ID,
  name: 'crisp-dev',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
}
const transport = http(RPC_URL)
const pub = createPublicClient({ chain, transport, pollingInterval: 500 })
const testClient = createTestClient({ chain, transport, mode: 'anvil' })
sdk.setCircuits(await loadCircuits())
const crisp = new sdk.CrispSDK(CRISP_SERVER_URL, RPC_URL)

// Fresh deterministic keys, so the demo never shares a nonce with the deployer, ciphernode or
// randomness accounts the CRISP stack is already sending from.
const keyOf = (label) => keccak256(toHex(`octant-crisp-demo:${label}`))
const actors = Object.fromEntries(
  ['operator', 'alice', 'bob', 'carol', 'project1', 'project2', 'project3'].map((label) => {
    const account = privateKeyToAccount(keyOf(label))
    return [label, { label, account, wallet: createWalletClient({ account, chain, transport }) }]
  }),
)

const mechanismArtifact = artifact('CrispAllocationMechanism.sol', 'CrispAllocationMechanism')
const tamArtifact = artifact('TokenizedAllocationMechanism.sol', 'TokenizedAllocationMechanism')
const erc20Artifact = artifact('ERC20Mock.sol', 'ERC20Mock')
// The mechanism proxy serves its own functions and delegates everything else to the TAM.
const seen = new Set()
const mechanismAbi = [...mechanismArtifact.abi, ...tamArtifact.abi].filter((item) => {
  if (item.type === 'constructor' || item.type === 'fallback' || item.type === 'receive') return item === mechanismArtifact.abi.find((i) => i.type === item.type)
  const key = `${item.type}:${item.name}:${(item.inputs ?? []).map((i) => i.type).join(',')}`
  if (seen.has(key)) return false
  seen.add(key)
  return true
})

const interfoldAbi = parseAbi([
  'function getE3Stage(uint256 e3Id) view returns (uint8)',
  'function getFailureReason(uint256 e3Id) view returns (uint8)',
])
const crispAbi = parseAbi([
  'function ballotDigest(uint256 e3Id, address slot, bytes32 ciphertextCommitment) view returns (bytes32)',
  'function pendingInputCount(uint256 e3Id) view returns (uint256)',
  'function getRoundData(uint256 e3Id) view returns (uint256 merkleRoot, bytes32 paramsHash, uint256 numOptions, uint8 creditMode, uint256 inputRoot, uint256 numberOfVotes)',
])
const mockUsdcAbi = parseAbi(['function mint(address to, uint256 amount)', 'function approve(address spender, uint256 amount) returns (bool)'])
const STAGES = ['None', 'Requested', 'CommitteeFinalized', 'KeyPublished', 'CiphertextReady', 'Complete', 'Failed']

async function send(actor, request) {
  const hash = await actor.wallet.writeContract({ ...request, account: actor.account, chain })
  const receipt = await pub.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error(`${request.functionName} reverted (${hash})`)
  return receipt
}

async function deploy(actor, { abi, bytecode }, args = []) {
  const hash = await actor.wallet.deployContract({ abi, bytecode, args, account: actor.account, chain })
  const receipt = await pub.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success' || !receipt.contractAddress) throw new Error(`deployment reverted (${hash})`)
  return receipt.contractAddress
}

async function now() {
  return (await pub.getBlock()).timestamp
}

async function warpTo(timestamp) {
  if ((await now()) >= timestamp) return
  await testClient.setNextBlockTimestamp({ timestamp })
  await testClient.mine({ blocks: 1 })
}

// --- 0. stack -----------------------------------------------------------------------------------
step('0. Local Interfold / CRISP stack')
const deployed = JSON.parse(readFileSync(join(CRISP_DIR, 'packages/crisp-contracts/deployed_contracts.json'), 'utf8')).localhost
const INTERFOLD = deployed.Interfold.address
const CRISP_PROGRAM = deployed.CRISPProgram.address
const FEE_TOKEN = deployed.MockUSDC.address
log(`Interfold ${INTERFOLD}`)
log(`CRISPProgram ${CRISP_PROGRAM}`)
await waitFor('ciphernodes to be registered (.interfold/ready)', () => existsSync(join(CRISP_DIR, '.interfold/ready')))
log('ciphernodes registered')

for (const actor of Object.values(actors)) {
  await testClient.setBalance({ address: actor.account.address, value: parseUnits('100', 18) })
}

// --- 1. deploy ----------------------------------------------------------------------------------
step('1. Deploy Octant CrispAllocationMechanism')
const { operator, alice, bob, carol, project1, project2, project3 } = actors
const VOTING_DELAY = 120n
const VOTING_PERIOD = 1800n
const TIMELOCK = 30n
const GRACE = 3600n

const asset = await deploy(operator, erc20Artifact)
const tamImpl = await deploy(operator, tamArtifact)
const mechanism = await deploy(operator, mechanismArtifact, [
  tamImpl,
  {
    asset,
    name: 'Octant CRISP Round',
    symbol: 'oCRISP',
    votingDelay: VOTING_DELAY,
    votingPeriod: VOTING_PERIOD,
    quorumShares: parseUnits('1', 18),
    timelockDelay: TIMELOCK,
    gracePeriod: GRACE,
    owner: operator.account.address,
  },
  INTERFOLD,
  CRISP_PROGRAM,
])
const read = (functionName, args = []) => pub.readContract({ address: mechanism, abi: mechanismAbi, functionName, args })
const call = (actor, functionName, args = []) => send(actor, { address: mechanism, abi: mechanismAbi, functionName, args })
const assetCall = (actor, functionName, args) => send(actor, { address: asset, abi: erc20Artifact.abi, functionName, args })
log(`asset (ERC20Mock) ${asset}`)
log(`mechanism ${mechanism}`)

// --- 2. signup + proposals ----------------------------------------------------------------------
step('2. Voters deposit (signup) and projects are proposed')
const deposits = [
  [alice, parseUnits('10', 18)],
  [bob, parseUnits('20', 18)],
  [carol, parseUnits('30', 18)],
]
for (const [voter, amount] of deposits) {
  await assetCall(operator, 'mint', [voter.account.address, amount])
  await assetCall(voter, 'approve', [mechanism, amount])
  await call(voter, 'signup', [amount])
  log(`${voter.label.padEnd(5)} deposited ${tokens(amount)} -> voting power ${tokens(await read('votingPower', [voter.account.address]))}`)
}
const MATCHING_POOL = parseUnits('600', 18)
await assetCall(operator, 'mint', [mechanism, MATCHING_POOL])
log(`matching pool funded with ${tokens(MATCHING_POOL)}`)

const projects = [project1, project2, project3]
for (const [i, project] of projects.entries()) {
  await call(operator, 'propose', [project.account.address, `Public good #${i + 1}`])
}
log(`proposed ${projects.length} projects`)

// --- 3. open round ------------------------------------------------------------------------------
step('3. openRound(): freeze census and request the CRISP E3')
const MAX_FEE = parseUnits('1000', 6)
await send(operator, { address: FEE_TOKEN, abi: mockUsdcAbi, functionName: 'mint', args: [operator.account.address, MAX_FEE] })
await send(operator, { address: FEE_TOKEN, abi: mockUsdcAbi, functionName: 'approve', args: [mechanism, MAX_FEE] })
const VOTING_POWER_DIVISOR = parseUnits('1', 18) // one ballot credit per deposited token
const openReceipt = await call(operator, 'openRound', [
  {
    committeeSize: 0, // Minimum (2-of-3)
    paramSet: 0, // insecure-512, local only
    expectedCryptoConfigId: CRYPTO_CONFIG_ID_PARAM_SET_0,
    computeProviderParams: '0x',
    votingPowerDivisor: VOTING_POWER_DIVISOR,
    maxFee: MAX_FEE,
  },
])
const [opened] = parseEventLogs({ abi: mechanismAbi, logs: openReceipt.logs, eventName: 'CrispRoundOpened' })
const e3Id = opened.args.e3Id
const optionPids = opened.args.optionPids
log(`E3 ${e3Id} requested, fee ${formatUnits(opened.args.fee, 6)} USDC`)
log(`ballot window [${opened.args.inputStart}, ${opened.args.inputEnd}], options -> pids ${optionPids.join(', ')}`)
log(`census snapshot ${await read('censusSnapshot')}, total power ${tokens(await read('censusTotalPower'))}`)

// --- 4. committee -------------------------------------------------------------------------------
step('4. Wait for the ciphernode committee to publish its key')
const stage = async () => Number(await pub.readContract({ address: INTERFOLD, abi: interfoldAbi, functionName: 'getE3Stage', args: [e3Id] }))
let lastStage = -1
await waitFor(
  'committee key',
  async () => {
    const s = await stage()
    if (s !== lastStage) log(`E3 stage: ${STAGES[s]}`)
    lastStage = s
    if (s === 6) throw new Error('E3 failed before key publication')
    return s >= 3
  },
  { timeoutMs: 900_000 },
)
const publicKey = await waitFor('committee public key on the CRISP server', async () => {
  try {
    return await crisp.getRoundPublicKey(e3Id)
  } catch {
    return undefined
  }
})
log(`committee public key: ${publicKey.length} bytes`)
await warpTo(opened.args.inputStart)

// --- 5. ballots ---------------------------------------------------------------------------------
step('5. Encrypted ballots (CRISP SDK -> CRISP server relay -> CRISPProgram)')

// A mask (`signer` omitted) adds an all-zero ballot to someone else's slot. It needs no signature
// and is indistinguishable on chain from a re-vote, which is what keeps re-votes deniable.
async function castBallot({ slot, signer, vote, note }) {
  const slotAddress = slot.account.address
  const isMaskVote = !signer
  const votingPower = await crisp.getOnchainVotingPower(CRISP_PROGRAM, e3Id, slotAddress, CHAIN_ID)
  const started = Date.now()
  const prepared = await crisp.prepareBallot({
    e3Id,
    censusMode: 'onchain',
    votingPower,
    publicKey,
    slotAddress,
    isMaskVote,
    numOptions: optionPids.length,
    vote,
  })
  const digest = await pub.readContract({ address: CRISP_PROGRAM, abi: crispAbi, functionName: 'ballotDigest', args: [e3Id, slotAddress, prepared.ctCommitment] })
  const signature = isMaskVote
    ? undefined
    : await signer.account.signTypedData({
        domain: { name: 'CRISP', version: '1', chainId: CHAIN_ID, verifyingContract: CRISP_PROGRAM },
        types: {
          Ballot: [
            { name: 'e3Id', type: 'uint256' },
            { name: 'slot', type: 'address' },
            { name: 'ciphertextCommitment', type: 'bytes32' },
          ],
        },
        primaryType: 'Ballot',
        message: { e3Id, slot: slotAddress, ciphertextCommitment: prepared.ctCommitment },
      })
  const proof = await crisp.finishBallot(prepared, digest, signature)
  const proofSecs = ((Date.now() - started) / 1000).toFixed(1)
  let res = await crisp.broadcastVote({ e3Id, encodedProof: sdk.encodeSolidityProof(proof) })
  while (res.status !== 'success') {
    if (res.status === 'failed_broadcast' || !res.job_id) throw new Error(`input on ${slot.label}'s slot rejected: ${res.message}`)
    await sleep(1_000)
    res = await crisp.getVoteAvailability(res.job_id)
  }
  const who = isMaskVote ? `mask on ${slot.label}'s slot` : `${slot.label} (credits=${votingPower})`
  log(`${who.padEnd(22)} ballot=[${vote.join(', ')}] proved in ${proofSecs}s  ${note}`)
}

async function waitForInputs(expected) {
  await waitFor(`${expected} committed inputs`, async () => {
    const [, , , , , numberOfVotes] = await pub.readContract({ address: CRISP_PROGRAM, abi: crispAbi, functionName: 'getRoundData', args: [e3Id] })
    const pending = await pub.readContract({ address: CRISP_PROGRAM, abi: crispAbi, functionName: 'pendingInputCount', args: [e3Id] })
    return numberOfVotes >= BigInt(expected) && pending === 0n
  })
}

await castBallot({ slot: bob, signer: bob, vote: [20, 0, 0], note: '<- cast in front of a coercer' })
await waitForInputs(1)
await castBallot({ slot: alice, signer: alice, vote: [7, 3, 0], note: '' })
await castBallot({ slot: carol, signer: carol, vote: [10, 5, 15], note: '' })
await waitForInputs(3)
await castBallot({ slot: alice, vote: [0, 0, 0], note: '<- anyone can add one, no signature' })
await waitForInputs(4)
await castBallot({ slot: bob, signer: bob, vote: [0, 15, 5], note: '<- later, alone: replaces his earlier ballot' })
await waitForInputs(5)
log("on chain: 5 opaque inputs, 2 on alice's slot and 2 on bob's; each second input could be a re-vote or a mask")

// --- 6. tally -----------------------------------------------------------------------------------
step('6. Close the ballot window; committee computes and threshold-decrypts the tally')
await warpTo(opened.args.inputEnd + 1n)
log('time advanced past votingEndTime')
await waitFor(
  'decrypted tally',
  async () => {
    const s = await stage()
    if (s !== lastStage) log(`E3 stage: ${STAGES[s]}`)
    lastStage = s
    if (s === 6) {
      const reason = await pub.readContract({ address: INTERFOLD, abi: interfoldAbi, functionName: 'getFailureReason', args: [e3Id] })
      throw new Error(`E3 failed (reason ${reason})`)
    }
    return s === 5
  },
  { timeoutMs: 1_200_000 },
)

// --- 7. Octant settlement -----------------------------------------------------------------------
step('7. Octant: finalizeVoteTally -> queueProposal -> redeem')
await call(operator, 'finalizeVoteTally')
const credits = []
for (const pid of optionPids) credits.push(await read('creditsOf', [pid]))
log(`decrypted credits per project: [${credits.join(', ')}] (expected [17, 23, 20])`)

for (const pid of optionPids) {
  await call(operator, 'queueProposal', [pid])
}
await warpTo((await read('globalRedemptionStart')) + 1n)

const totalAssets = await read('totalAssets')
const rows = []
for (const [i, pid] of optionPids.entries()) {
  const project = projects[i]
  const shares = await read('balanceOf', [project.account.address])
  await call(project, 'redeem', [shares, project.account.address, project.account.address])
  const received = await pub.readContract({ address: asset, abi: erc20Artifact.abi, functionName: 'balanceOf', args: [project.account.address] })
  rows.push({ pid: Number(pid), recipient: project.account.address, credits: Number(credits[i]), shares: tokens(shares), received: tokens(received) })
}
console.log()
console.table(rows)
log(`pool distributed: ${tokens(totalAssets)} tokens (600 matching + 60 deposits), pro rata to decrypted credits`)
log('done')
process.exit(0)

# Hello FHEVM: Building Your First Confidential dApp

A complete beginner's guide to creating privacy-preserving applications using Fully Homomorphic Encryption (FHE) on Zama Protocol.

## 🎯 What You'll Build

By the end of this tutorial, you'll have created a **Privacy Procurement System** - a confidential bidding platform where bid amounts remain encrypted throughout the entire process. This real-world example demonstrates core FHE concepts while building something genuinely useful.

**Live Demo**: https://privacy-procurement-final.vercel.app/

## 📚 Prerequisites

Before starting, ensure you have:

- ✅ Basic Solidity knowledge (can write and deploy simple smart contracts)
- ✅ Familiarity with Ethereum tools (MetaMask, Hardhat/Foundry)
- ✅ Basic web development skills (HTML, CSS, JavaScript)
- ❌ **NO** advanced mathematics or cryptography knowledge required!
- ❌ **NO** prior FHE experience needed

## 🎓 Learning Objectives

After completing this tutorial, you will:

1. **Understand FHE Fundamentals**: Learn what Fully Homomorphic Encryption is and why it's revolutionary
2. **Write FHE Smart Contracts**: Create contracts that process encrypted data
3. **Build Confidential dApps**: Develop frontend applications that handle encrypted inputs
4. **Deploy on FHEVM**: Launch your first privacy-preserving application
5. **Master Core Patterns**: Understand common FHE development patterns for future projects

## 🧠 Chapter 1: Understanding FHE and FHEVM

### What is Fully Homomorphic Encryption?

Imagine you could perform calculations on locked boxes without opening them, and the results would still be correct when unlocked. That's essentially what FHE does with encrypted data!

```
Traditional Encryption:
Encrypt → Store → Decrypt to compute → Re-encrypt

FHE (Revolutionary):
Encrypt → Compute directly on encrypted data → Decrypt final result
```

### Why FHE Matters for Web3

Traditional smart contracts expose all data publicly. FHE enables:

- **Private Voting**: Vote without revealing your choice
- **Confidential Auctions**: Bid without showing your amount
- **Secret Calculations**: Compute on sensitive data privately
- **Privacy-First dApps**: Build applications that truly protect user data

### FHEVM: FHE on Ethereum

Zama's FHEVM brings FHE to Ethereum, allowing smart contracts to:
- Process encrypted integers (`euint8`, `euint16`, `euint32`, `euint64`)
- Perform operations (+, -, *, /, comparisons) on encrypted data
- Return encrypted results that only authorized parties can decrypt

## 💡 Chapter 2: Core FHE Concepts

### Encrypted Types

FHEVM introduces new data types that work like regular integers but remain encrypted:

```solidity
euint8 encryptedAge;        // 0-255, encrypted
euint16 encryptedScore;     // 0-65535, encrypted
euint32 encryptedAmount;    // 0-4billion+, encrypted
euint64 encryptedBigValue;  // Very large numbers, encrypted
```

### FHE Operations

You can perform operations on encrypted data just like regular data:

```solidity
euint32 encryptedA = FHE.asEuint32(100);  // Encrypt 100
euint32 encryptedB = FHE.asEuint32(50);   // Encrypt 50
euint32 result = FHE.add(encryptedA, encryptedB);  // Encrypted 150!
```

### Access Control

Control who can decrypt your encrypted data:

```solidity
// Allow the contract to access encrypted data
FHE.allowThis(encryptedValue);

// Allow specific address to decrypt
FHE.allow(encryptedValue, userAddress);
```

## 🏗️ Chapter 3: Building the Smart Contract

### Step 1: Contract Setup

First, let's create our procurement contract structure:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint64, euint8, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract PrivacyProcurement is SepoliaConfig {
    address public procurementAuthority;
    uint256 public currentTenderId;

    // Tender status enumeration
    enum TenderStatus { Open, Closed, Evaluated, Awarded, Cancelled }
```

**Key Learning Points:**
- Import FHE library and encrypted types
- Extend SepoliaConfig for FHEVM compatibility
- Use standard Solidity patterns alongside FHE

### Step 2: Data Structures

Define structures that mix public and encrypted data:

```solidity
struct Tender {
    string title;                    // Public
    string description;              // Public
    uint256 budget;                  // Public
    uint256 deadline;                // Public
    TenderStatus status;             // Public
    address winner;                  // Public (after evaluation)
    uint256 winningBid;              // Public (after evaluation)
    uint256 createdAt;               // Public
    address[] bidders;               // Public
    bool requiresQualification;      // Public
}

struct EncryptedBid {
    euint64 encryptedAmount;         // 🔒 ENCRYPTED - The bid amount
    euint8 qualificationScore;       // 🔒 ENCRYPTED - Supplier rating
    string publicProposal;           // Public description
    bool submitted;                  // Public flag
    uint256 timestamp;               // Public
    address bidder;                  // Public
}
```

**Key Learning Points:**
- Mix encrypted and public data strategically
- Keep metadata public for usability
- Encrypt only sensitive values (bid amounts, scores)

### Step 3: Encryption in Action

Implement the core bidding function:

```solidity
function submitBid(
    uint256 tenderId,
    uint64 bidAmount,           // Plain input from user
    string memory proposal
) external onlyRegisteredSupplier tenderExists(tenderId) tenderOpen(tenderId) {

    // 🔒 ENCRYPT the sensitive bid amount
    euint64 encryptedBidAmount = FHE.asEuint64(bidAmount);

    // 🔒 ENCRYPT the supplier's qualification score
    euint8 qualificationScore = FHE.asEuint8(suppliers[msg.sender].reputationScore);

    // Store the encrypted bid
    tenderBids[tenderId][msg.sender] = EncryptedBid({
        encryptedAmount: encryptedBidAmount,
        qualificationScore: qualificationScore,
        publicProposal: proposal,
        submitted: true,
        timestamp: block.timestamp,
        bidder: msg.sender
    });

    // 🔑 SET ACCESS PERMISSIONS
    FHE.allowThis(encryptedBidAmount);                    // Contract can access
    FHE.allow(encryptedBidAmount, msg.sender);            // Bidder can access
    FHE.allow(encryptedBidAmount, procurementAuthority);  // Authority can access

    emit BidSubmitted(tenderId, msg.sender, block.timestamp);
}
```

**Key Learning Points:**
- Convert plain input to encrypted with `FHE.asEuint64()`
- Set access permissions carefully
- Encrypted data can coexist with public data

### Step 4: Computing on Encrypted Data

The winner selection happens entirely on encrypted data:

```solidity
function evaluateTender(uint256 tenderId) external onlyAuthority tenderExists(tenderId) {
    require(tenders[tenderId].status == TenderStatus.Closed, "Tender not closed");

    Tender storage tender = tenders[tenderId];

    // Prepare encrypted data for batch decryption
    bytes32[] memory cts = new bytes32[](tender.bidders.length * 2);
    uint256 index = 0;

    // Collect all encrypted bid data
    for (uint256 i = 0; i < tender.bidders.length; i++) {
        address bidder = tender.bidders[i];
        EncryptedBid storage bid = tenderBids[tenderId][bidder];

        cts[index] = FHE.toBytes32(bid.encryptedAmount);        // Bid amount
        cts[index + 1] = FHE.toBytes32(bid.qualificationScore); // Quality score
        index += 2;
    }

    // Request asynchronous decryption
    FHE.requestDecryption(cts, this.processEvaluation.selector);
    tender.status = TenderStatus.Evaluated;
}
```

**Key Learning Points:**
- FHE enables batch processing of encrypted data
- Asynchronous decryption for efficiency
- Smart contracts can request decryption when needed

## 🌐 Chapter 4: Building the Frontend

### Step 1: Web3 Setup with FHE Support

Initialize your Web3 connection with FHE capabilities:

```javascript
// Load ethers.js for blockchain interaction
const contractAddress = "0xeE2E4Ec62f4A4846626bDe4a362e7e8A4D1256D7";
const contractABI = [
    "function submitBid(uint256 tenderId, uint64 bidAmount, string memory proposal) external",
    "function getTenderInfo(uint256 tenderId) external view returns (string memory, string memory, uint256, uint256, uint8, address, uint256, uint256)",
    // ... other functions
];

async function initWeb3() {
    if (typeof window.ethereum !== 'undefined') {
        provider = new ethers.providers.Web3Provider(window.ethereum);
        await window.ethereum.request({ method: 'eth_requestAccounts' });
        signer = provider.getSigner();
        contract = new ethers.Contract(contractAddress, contractABI, signer);
    }
}
```

### Step 2: Handling Encrypted Inputs

Create functions that handle both public and encrypted data:

```javascript
async function submitBid() {
    const tenderId = document.getElementById('bidTenderId').value;
    const bidAmountEth = parseFloat(document.getElementById('bidAmount').value);
    const proposal = document.getElementById('bidProposal').value;

    // Convert ETH to wei for precise calculation
    const bidAmountWei = Math.floor(bidAmountEth * 1e18);

    try {
        // The smart contract will encrypt this value
        const tx = await contract.submitBid(tenderId, bidAmountWei, proposal);
        await tx.wait();

        alert('🔒 Bid submitted successfully! Your bid amount is encrypted and confidential.');
    } catch (error) {
        alert('Failed to submit bid: ' + error.message);
    }
}
```

**Key Learning Points:**
- Frontend sends plain values
- Smart contract handles encryption
- User sees confirmation that data is encrypted

### Step 3: Displaying Encrypted vs Public Data

Show users what's public vs private:

```javascript
function displayBids(bids) {
    return bids.map(bid => `
        <div class="bid-card">
            <h3>Bid from ${bid.bidder.substring(0, 6)}...</h3>
            <p><strong>Proposal:</strong> ${bid.publicProposal}</p>
            <p><strong>Submission Time:</strong> ${new Date(bid.timestamp * 1000).toLocaleString()}</p>
            <p><strong>Bid Amount:</strong> 🔒 Encrypted (Private)</p>
            <p class="privacy-note">💡 Bid amount remains confidential until evaluation</p>
        </div>
    `).join('');
}
```

## 🚀 Chapter 5: Deployment and Testing

### Step 1: Deploy to Sepolia

Your contract is ready for Sepolia testnet:

```bash
# Install dependencies
npm install @fhevm/solidity

# Deploy to Sepolia
npx hardhat deploy --network sepolia
```

### Step 2: Test the Privacy Features

Verify that your FHE implementation works:

1. **Submit Multiple Bids**: Have different accounts submit various bid amounts
2. **Verify Privacy**: Confirm bid amounts aren't visible on-chain
3. **Test Evaluation**: Run the evaluation process and verify winner selection
4. **Check Access Control**: Ensure only authorized parties can decrypt results

### Step 3: Frontend Integration

Connect your deployed contract to the frontend:

1. Update contract address in your JavaScript
2. Test MetaMask connection on Sepolia
3. Verify encrypted bid submission
4. Test the complete procurement flow

## 🎓 Chapter 6: Advanced FHE Patterns

### Pattern 1: Conditional Logic with Encrypted Data

```solidity
// Compare encrypted values
function selectBestBid(euint64 bidA, euint64 bidB, euint8 scoreA, euint8 scoreB)
    internal returns (ebool) {

    ebool lowerBid = FHE.lt(bidA, bidB);  // bidA < bidB ?
    ebool higherScore = FHE.gt(scoreA, scoreB);  // scoreA > scoreB ?

    // Complex logic: lower bid OR (equal bid AND higher score)
    ebool equalBid = FHE.eq(bidA, bidB);
    ebool betterChoice = FHE.or(lowerBid, FHE.and(equalBid, higherScore));

    return betterChoice;
}
```

### Pattern 2: Batch Operations

```solidity
function processBatchBids(euint64[] memory bids) internal returns (euint64) {
    euint64 lowestBid = bids[0];

    for (uint256 i = 1; i < bids.length; i++) {
        ebool isLower = FHE.lt(bids[i], lowestBid);
        lowestBid = FHE.select(isLower, bids[i], lowestBid);
    }

    return lowestBid;
}
```

### Pattern 3: Time-Based Access Control

```solidity
modifier onlyDuringEvaluation(uint256 tenderId) {
    require(block.timestamp > tenders[tenderId].deadline, "Evaluation period not started");
    require(tenders[tenderId].status == TenderStatus.Closed, "Tender not ready for evaluation");
    _;
}
```

## 🏆 Chapter 7: Production Considerations

### Gas Optimization

FHE operations consume more gas than regular operations:

```solidity
// Efficient: Batch operations
function batchEvaluate(uint256[] memory tenderIds) external {
    for (uint256 i = 0; i < tenderIds.length; i++) {
        evaluateTender(tenderIds[i]);
    }
}

// Efficient: Minimize FHE operations
function quickCheck(euint64 encrypted, uint64 threshold) internal returns (ebool) {
    euint64 encryptedThreshold = FHE.asEuint64(threshold);  // Only encrypt once
    return FHE.gte(encrypted, encryptedThreshold);
}
```

### Security Best Practices

1. **Access Control**: Always set proper permissions with `FHE.allow()`
2. **Input Validation**: Validate public inputs before encryption
3. **Event Logging**: Log public events for transparency
4. **Upgrade Patterns**: Plan for contract upgrades if needed

### Error Handling

```javascript
async function safeContractCall(contractMethod, ...args) {
    try {
        const tx = await contractMethod(...args);
        const receipt = await tx.wait();
        return { success: true, receipt };
    } catch (error) {
        if (error.code === 4001) {
            return { success: false, error: 'User rejected transaction' };
        } else if (error.message.includes('insufficient funds')) {
            return { success: false, error: 'Insufficient funds for gas' };
        } else {
            return { success: false, error: error.message };
        }
    }
}
```

## 🌟 What You've Accomplished

Congratulations! You've just built your first confidential dApp with FHE. Here's what you've learned:

### ✅ Core FHE Skills
- **Encrypted Data Types**: Working with `euint8`, `euint64`, and other FHE types
- **Encryption/Decryption**: Converting between plain and encrypted data
- **Access Control**: Managing who can decrypt sensitive information
- **Encrypted Operations**: Performing calculations on encrypted data

### ✅ Smart Contract Patterns
- **Mixed Data Structures**: Combining public and encrypted fields
- **Asynchronous Processing**: Handling FHE decryption workflows
- **Event Management**: Logging activities while preserving privacy
- **Gas Optimization**: Efficient FHE operation patterns

### ✅ Frontend Integration
- **Web3 Connection**: Connecting to FHEVM networks
- **User Experience**: Showing encryption status to users
- **Error Handling**: Graceful handling of FHE-specific errors
- **Privacy UI/UX**: Designing interfaces that respect privacy

## 🚀 Next Steps

Ready to build more advanced FHE applications? Consider these next projects:

1. **Private Voting System**: Create anonymous voting with encrypted ballots
2. **Confidential Trading**: Build a private order book for trading
3. **Secret Auctions**: Implement various auction mechanisms with FHE
4. **Privacy-Preserving Analytics**: Aggregate data without revealing individual entries
5. **Secure Multi-Party Computation**: Enable parties to compute together privately

## 📚 Additional Resources

- **Zama Documentation**: https://docs.zama.ai/fhevm
- **FHEVM Examples**: https://github.com/zama-ai/fhevm
- **Community Discord**: Join the Zama developer community
- **Tutorial Repository**: https://github.com/GilbertoHackett/PrivacyProcurementFinal

---

**Congratulations!** 🎉 You've mastered the fundamentals of building confidential dApps with FHE. The future of privacy-preserving applications starts with developers like you who understand that true privacy requires encryption that never stops protecting data - even during computation.

**Happy Building!** 🔒⚡
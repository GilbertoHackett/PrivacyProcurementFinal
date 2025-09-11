// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint64, euint8, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract PrivacyProcurement is SepoliaConfig {

    address public procurementAuthority;
    uint256 public currentTenderId;

    enum TenderStatus {
        Open,
        Closed,
        Evaluated,
        Awarded,
        Cancelled
    }

    struct Tender {
        string title;
        string description;
        uint256 budget;
        uint256 deadline;
        TenderStatus status;
        address winner;
        uint256 winningBid;
        uint256 createdAt;
        address[] bidders;
        bool requiresQualification;
    }

    struct EncryptedBid {
        euint64 encryptedAmount;
        euint8 qualificationScore;
        string publicProposal;
        bool submitted;
        uint256 timestamp;
        address bidder;
    }

    struct Supplier {
        string name;
        string category;
        bool isRegistered;
        bool isQualified;
        uint256 registrationDate;
        uint8 reputationScore;
    }

    mapping(uint256 => Tender) public tenders;
    mapping(uint256 => mapping(address => EncryptedBid)) public tenderBids;
    mapping(address => Supplier) public suppliers;
    mapping(uint256 => address[]) public tenderBidders;

    event TenderCreated(uint256 indexed tenderId, string title, uint256 budget, uint256 deadline);
    event BidSubmitted(uint256 indexed tenderId, address indexed bidder, uint256 timestamp);
    event TenderClosed(uint256 indexed tenderId, uint256 timestamp);
    event TenderAwarded(uint256 indexed tenderId, address indexed winner, uint256 amount);
    event SupplierRegistered(address indexed supplier, string name);
    event SupplierQualified(address indexed supplier, uint8 score);

    modifier onlyAuthority() {
        require(msg.sender == procurementAuthority, "Only procurement authority");
        _;
    }

    modifier onlyRegisteredSupplier() {
        require(suppliers[msg.sender].isRegistered, "Supplier not registered");
        _;
    }

    modifier tenderExists(uint256 tenderId) {
        require(tenderId > 0 && tenderId <= currentTenderId, "Tender does not exist");
        _;
    }

    modifier tenderOpen(uint256 tenderId) {
        require(tenders[tenderId].status == TenderStatus.Open, "Tender not open");
        require(block.timestamp < tenders[tenderId].deadline, "Tender deadline passed");
        _;
    }

    constructor() {
        procurementAuthority = msg.sender;
        currentTenderId = 0;
    }

    function registerSupplier(
        string memory _name,
        string memory _category
    ) external {
        require(!suppliers[msg.sender].isRegistered, "Already registered");
        require(bytes(_name).length > 0, "Name required");

        suppliers[msg.sender] = Supplier({
            name: _name,
            category: _category,
            isRegistered: true,
            isQualified: false,
            registrationDate: block.timestamp,
            reputationScore: 50
        });

        emit SupplierRegistered(msg.sender, _name);
    }

    function qualifySupplier(
        address supplier,
        uint8 qualificationScore
    ) external onlyAuthority {
        require(suppliers[supplier].isRegistered, "Supplier not registered");
        require(qualificationScore <= 100, "Score must be 0-100");

        suppliers[supplier].isQualified = true;
        suppliers[supplier].reputationScore = qualificationScore;

        emit SupplierQualified(supplier, qualificationScore);
    }

    function createTender(
        string memory _title,
        string memory _description,
        uint256 _budget,
        uint256 _deadline,
        bool _requiresQualification
    ) external onlyAuthority returns (uint256) {
        require(bytes(_title).length > 0, "Title required");
        require(_deadline > block.timestamp, "Invalid deadline");
        require(_budget > 0, "Budget must be positive");

        currentTenderId++;

        tenders[currentTenderId] = Tender({
            title: _title,
            description: _description,
            budget: _budget,
            deadline: _deadline,
            status: TenderStatus.Open,
            winner: address(0),
            winningBid: 0,
            createdAt: block.timestamp,
            bidders: new address[](0),
            requiresQualification: _requiresQualification
        });

        emit TenderCreated(currentTenderId, _title, _budget, _deadline);
        return currentTenderId;
    }

    function submitBid(
        uint256 tenderId,
        uint64 bidAmount,
        string memory proposal
    ) external
        onlyRegisteredSupplier
        tenderExists(tenderId)
        tenderOpen(tenderId)
    {
        Tender storage tender = tenders[tenderId];

        if (tender.requiresQualification) {
            require(suppliers[msg.sender].isQualified, "Supplier not qualified");
        }

        require(!tenderBids[tenderId][msg.sender].submitted, "Bid already submitted");
        require(bidAmount > 0, "Bid amount must be positive");
        require(bytes(proposal).length > 0, "Proposal required");

        euint64 encryptedBidAmount = FHE.asEuint64(bidAmount);
        euint8 qualificationScore = FHE.asEuint8(suppliers[msg.sender].reputationScore);

        tenderBids[tenderId][msg.sender] = EncryptedBid({
            encryptedAmount: encryptedBidAmount,
            qualificationScore: qualificationScore,
            publicProposal: proposal,
            submitted: true,
            timestamp: block.timestamp,
            bidder: msg.sender
        });

        tenders[tenderId].bidders.push(msg.sender);

        FHE.allowThis(encryptedBidAmount);
        FHE.allow(encryptedBidAmount, msg.sender);
        FHE.allow(encryptedBidAmount, procurementAuthority);

        FHE.allowThis(qualificationScore);
        FHE.allow(qualificationScore, msg.sender);
        FHE.allow(qualificationScore, procurementAuthority);

        emit BidSubmitted(tenderId, msg.sender, block.timestamp);
    }

    function closeTender(uint256 tenderId)
        external
        onlyAuthority
        tenderExists(tenderId)
    {
        require(tenders[tenderId].status == TenderStatus.Open, "Tender not open");

        tenders[tenderId].status = TenderStatus.Closed;
        emit TenderClosed(tenderId, block.timestamp);
    }

    function evaluateTender(uint256 tenderId)
        external
        onlyAuthority
        tenderExists(tenderId)
    {
        require(tenders[tenderId].status == TenderStatus.Closed, "Tender not closed");
        require(tenders[tenderId].bidders.length > 0, "No bids submitted");

        Tender storage tender = tenders[tenderId];

        bytes32[] memory cts = new bytes32[](tender.bidders.length * 2);
        uint256 index = 0;

        for (uint256 i = 0; i < tender.bidders.length; i++) {
            address bidder = tender.bidders[i];
            EncryptedBid storage bid = tenderBids[tenderId][bidder];

            cts[index] = FHE.toBytes32(bid.encryptedAmount);
            cts[index + 1] = FHE.toBytes32(bid.qualificationScore);
            index += 2;
        }

        FHE.requestDecryption(cts, this.processEvaluation.selector);
        tender.status = TenderStatus.Evaluated;
    }

    function processEvaluation(
        uint256 requestId,
        uint64[] memory decryptedAmounts,
        bytes[] memory signatures
    ) external {
        // Basic validation - in production, implement proper signature verification
        require(decryptedAmounts.length > 0, "No decrypted amounts");
        require(decryptedAmounts.length % 2 == 0, "Invalid amount array length");

        uint256 tenderId = currentTenderId;
        Tender storage tender = tenders[tenderId];

        uint256 bestBidIndex = 0;
        uint64 lowestAmount = decryptedAmounts[0];
        uint8 bestScore = uint8(decryptedAmounts[1] & 0xFF);

        for (uint256 i = 0; i < tender.bidders.length; i++) {
            uint64 bidAmount = decryptedAmounts[i * 2];
            uint8 qualScore = uint8(decryptedAmounts[i * 2 + 1] & 0xFF);

            bool isBetter = (bidAmount < lowestAmount) ||
                           (bidAmount == lowestAmount && qualScore > bestScore);

            if (isBetter) {
                bestBidIndex = i;
                lowestAmount = bidAmount;
                bestScore = qualScore;
            }
        }

        tender.winner = tender.bidders[bestBidIndex];
        tender.winningBid = lowestAmount;
        tender.status = TenderStatus.Awarded;

        suppliers[tender.winner].reputationScore = _min(100, suppliers[tender.winner].reputationScore + 5);

        emit TenderAwarded(tenderId, tender.winner, lowestAmount);
    }

    function cancelTender(uint256 tenderId)
        external
        onlyAuthority
        tenderExists(tenderId)
    {
        require(tenders[tenderId].status == TenderStatus.Open, "Cannot cancel");
        tenders[tenderId].status = TenderStatus.Cancelled;
    }

    function getTenderInfo(uint256 tenderId)
        external
        view
        tenderExists(tenderId)
        returns (
            string memory title,
            string memory description,
            uint256 budget,
            uint256 deadline,
            TenderStatus status,
            address winner,
            uint256 winningBid,
            uint256 bidderCount
        )
    {
        Tender storage tender = tenders[tenderId];
        return (
            tender.title,
            tender.description,
            tender.budget,
            tender.deadline,
            tender.status,
            tender.winner,
            tender.winningBid,
            tender.bidders.length
        );
    }

    function getSupplierInfo(address supplier)
        external
        view
        returns (
            string memory name,
            string memory category,
            bool isRegistered,
            bool isQualified,
            uint256 registrationDate,
            uint8 reputationScore
        )
    {
        Supplier storage sup = suppliers[supplier];
        return (
            sup.name,
            sup.category,
            sup.isRegistered,
            sup.isQualified,
            sup.registrationDate,
            sup.reputationScore
        );
    }

    function getBidInfo(uint256 tenderId, address bidder)
        external
        view
        tenderExists(tenderId)
        returns (
            string memory publicProposal,
            bool submitted,
            uint256 timestamp
        )
    {
        EncryptedBid storage bid = tenderBids[tenderId][bidder];
        return (
            bid.publicProposal,
            bid.submitted,
            bid.timestamp
        );
    }

    function getTenderBidders(uint256 tenderId)
        external
        view
        tenderExists(tenderId)
        returns (address[] memory)
    {
        return tenders[tenderId].bidders;
    }

    function _min(uint8 a, uint8 b) private pure returns (uint8) {
        return a < b ? a : b;
    }
}
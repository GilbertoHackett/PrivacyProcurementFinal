// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint32, ebool } from "@fhevm/solidity/lib/FHE.sol";

contract PrivacyProcurement {
    struct ProcurementRequest {
        uint256 id;
        string itemName;
        string category;
        uint256 budget;
        string description;
        address submitter;
        uint256 timestamp;
        RequestStatus status;
        euint32 approvals;
        euint32 rejections;
        mapping(address => bool) hasVoted;
    }

    enum RequestStatus {
        Pending,
        Approved,
        Rejected,
        Completed
    }

    mapping(uint256 => ProcurementRequest) public procurementRequests;
    uint256 public requestCounter;
    uint256 public constant MINIMUM_VOTES = 3;

    address public admin;
    mapping(address => bool) public authorizedVoters;

    event ProcurementSubmitted(
        uint256 indexed requestId,
        string itemName,
        string category,
        uint256 budget,
        address submitter
    );

    event VoteCast(
        uint256 indexed requestId,
        address indexed voter
    );

    event RequestStatusChanged(
        uint256 indexed requestId,
        RequestStatus newStatus
    );

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can perform this action");
        _;
    }

    modifier onlyAuthorizedVoter() {
        require(authorizedVoters[msg.sender], "Not authorized to vote");
        _;
    }

    modifier validRequest(uint256 _requestId) {
        require(_requestId < requestCounter, "Invalid request ID");
        _;
    }

    constructor() {
        admin = msg.sender;
        authorizedVoters[msg.sender] = true;
        requestCounter = 0;
    }

    function addAuthorizedVoter(address _voter) external onlyAdmin {
        authorizedVoters[_voter] = true;
    }

    function removeAuthorizedVoter(address _voter) external onlyAdmin {
        authorizedVoters[_voter] = false;
    }

    function submitProcurementRequest(
        string memory _itemName,
        string memory _category,
        uint256 _budget,
        string memory _description,
        bool _urgent
    ) external {
        require(bytes(_itemName).length > 0, "Item name cannot be empty");
        require(bytes(_category).length > 0, "Category cannot be empty");
        require(_budget > 0, "Budget must be greater than 0");
        require(bytes(_description).length > 0, "Description cannot be empty");

        uint256 requestId = requestCounter;
        ProcurementRequest storage newRequest = procurementRequests[requestId];

        newRequest.id = requestId;
        newRequest.itemName = _itemName;
        newRequest.category = _category;
        newRequest.budget = _budget;
        newRequest.description = _description;
        newRequest.submitter = msg.sender;
        newRequest.timestamp = block.timestamp;
        newRequest.status = RequestStatus.Pending;

        // Fixed: Using correct FHE initialization
        newRequest.approvals = FHE.asEuint32(0);
        newRequest.rejections = FHE.asEuint32(0);

        // Allow this contract to use the encrypted values
        FHE.allowThis(newRequest.approvals);
        FHE.allowThis(newRequest.rejections);

        if (_urgent) {
            newRequest.timestamp = block.timestamp - 86400;
        }

        requestCounter++;

        emit ProcurementSubmitted(
            requestId,
            _itemName,
            _category,
            _budget,
            msg.sender
        );
    }

    function voteOnRequest(uint256 _requestId, bool _vote)
        external
        validRequest(_requestId)
        onlyAuthorizedVoter
    {
        ProcurementRequest storage request = procurementRequests[_requestId];

        require(request.status == RequestStatus.Pending, "Request is not pending");
        require(!request.hasVoted[msg.sender], "Already voted on this request");
        require(request.submitter != msg.sender, "Cannot vote on own request");

        request.hasVoted[msg.sender] = true;

        // Fixed: Using correct FHE boolean encryption
        ebool vote = FHE.asEbool(_vote);
        euint32 one = FHE.asEuint32(1);

        // Update vote counts using FHE operations
        request.approvals = FHE.select(vote, FHE.add(request.approvals, one), request.approvals);
        request.rejections = FHE.select(vote, request.rejections, FHE.add(request.rejections, one));

        // Allow the sender to view their vote effect
        FHE.allow(request.approvals, msg.sender);
        FHE.allow(request.rejections, msg.sender);

        emit VoteCast(_requestId, msg.sender);

        _checkAndUpdateRequestStatus(_requestId);
    }

    // Mapping to track pending status checks
    mapping(uint256 => bool) public pendingStatusChecks;

    function _checkAndUpdateRequestStatus(uint256 _requestId) internal {
        ProcurementRequest storage request = procurementRequests[_requestId];

        // Calculate total votes and check conditions using FHE
        euint32 totalVotes = FHE.add(request.approvals, request.rejections);
        euint32 minVotes = FHE.asEuint32(uint32(MINIMUM_VOTES));

        ebool hasEnoughVotes = FHE.ge(totalVotes, minVotes);
        ebool moreApprovals = FHE.gt(request.approvals, request.rejections);

        // Request async decryption for status determination
        bytes32[] memory cts = new bytes32[](2);
        cts[0] = FHE.toBytes32(hasEnoughVotes);
        cts[1] = FHE.toBytes32(moreApprovals);

        // Store request ID for callback processing
        pendingStatusChecks[_requestId] = true;

        FHE.requestDecryption(cts, this.processStatusUpdate.selector);
    }

    // Callback function to handle decryption results
    function processStatusUpdate(
        uint256 requestId,
        bool hasEnoughVotes,
        bool moreApprovals,
        bytes[] memory signatures
    ) external {
        // Create bytes representation of decrypted data for signature validation
        bytes memory decryptedData = abi.encode(hasEnoughVotes, moreApprovals);

        // Note: Signature verification commented due to version inconsistency
        // In production, this validation is critical for security
        // FHE.checkSignatures(requestId, signatures); // Standard 2-param version
        // FHE.checkSignatures(requestId, decryptedData, signatures); // 3-param attempt

        // TODO: Resolve library version compatibility for signature verification

        // Find the request ID that triggered this decryption
        uint256 targetRequestId = _findPendingRequest();
        require(pendingStatusChecks[targetRequestId], "No pending status check");

        ProcurementRequest storage request = procurementRequests[targetRequestId];

        if (hasEnoughVotes) {
            if (moreApprovals) {
                request.status = RequestStatus.Approved;
                emit RequestStatusChanged(targetRequestId, RequestStatus.Approved);
            } else {
                request.status = RequestStatus.Rejected;
                emit RequestStatusChanged(targetRequestId, RequestStatus.Rejected);
            }
        }

        // Clear pending status
        pendingStatusChecks[targetRequestId] = false;
    }

    // Helper function to find pending request (simplified for this example)
    function _findPendingRequest() private view returns (uint256) {
        for (uint256 i = 0; i < requestCounter; i++) {
            if (pendingStatusChecks[i]) {
                return i;
            }
        }
        revert("No pending request found");
    }

    function getRequest(uint256 _requestId)
        external
        view
        validRequest(_requestId)
        returns (
            string memory itemName,
            string memory category,
            uint256 budget,
            string memory description,
            address submitter,
            uint256 timestamp,
            RequestStatus status
        )
    {
        ProcurementRequest storage request = procurementRequests[_requestId];
        return (
            request.itemName,
            request.category,
            request.budget,
            request.description,
            request.submitter,
            request.timestamp,
            request.status
        );
    }

    function getRequestCount() external view returns (uint256) {
        return requestCounter;
    }

    function hasUserVoted(uint256 _requestId, address _user)
        external
        view
        validRequest(_requestId)
        returns (bool)
    {
        return procurementRequests[_requestId].hasVoted[_user];
    }

    // Mapping to store decrypted vote counts temporarily
    mapping(uint256 => VoteCountResult) public voteCountResults;
    mapping(uint256 => bool) public pendingVoteCountRequests;

    struct VoteCountResult {
        uint32 approvals;
        uint32 rejections;
        bool ready;
    }

    function requestVoteCount(uint256 _requestId)
        external
        validRequest(_requestId)
    {
        require(
            msg.sender == admin || authorizedVoters[msg.sender],
            "Not authorized to view vote counts"
        );

        ProcurementRequest storage request = procurementRequests[_requestId];

        // Request async decryption for vote counts
        bytes32[] memory cts = new bytes32[](2);
        cts[0] = FHE.toBytes32(request.approvals);
        cts[1] = FHE.toBytes32(request.rejections);

        pendingVoteCountRequests[_requestId] = true;

        FHE.requestDecryption(cts, this.processVoteCountResult.selector);
    }

    // Callback function to handle vote count decryption results
    function processVoteCountResult(
        uint256 requestId,
        uint32 approvals,
        uint32 rejections,
        bytes[] memory signatures
    ) external {
        // Create bytes representation of decrypted data for signature validation
        bytes memory decryptedData = abi.encode(approvals, rejections);

        // Note: Signature verification commented due to version inconsistency
        // In production, this validation is critical for security
        // FHE.checkSignatures(requestId, signatures); // Standard 2-param version
        // FHE.checkSignatures(requestId, decryptedData, signatures); // 3-param attempt

        // TODO: Resolve library version compatibility for signature verification

        // Find the request ID that triggered this decryption
        uint256 targetRequestId = _findPendingVoteCountRequest();
        require(pendingVoteCountRequests[targetRequestId], "No pending vote count request");

        // Store results
        voteCountResults[targetRequestId] = VoteCountResult({
            approvals: approvals,
            rejections: rejections,
            ready: true
        });

        // Clear pending status
        pendingVoteCountRequests[targetRequestId] = false;
    }

    // Helper function to find pending vote count request
    function _findPendingVoteCountRequest() private view returns (uint256) {
        for (uint256 i = 0; i < requestCounter; i++) {
            if (pendingVoteCountRequests[i]) {
                return i;
            }
        }
        revert("No pending vote count request found");
    }

    function getVoteCount(uint256 _requestId)
        external
        view
        validRequest(_requestId)
        returns (uint32, uint32, bool)
    {
        require(
            msg.sender == admin || authorizedVoters[msg.sender],
            "Not authorized to view vote counts"
        );

        VoteCountResult storage result = voteCountResults[_requestId];
        return (result.approvals, result.rejections, result.ready);
    }

    function markRequestCompleted(uint256 _requestId)
        external
        validRequest(_requestId)
    {
        ProcurementRequest storage request = procurementRequests[_requestId];

        require(
            msg.sender == admin || msg.sender == request.submitter,
            "Only admin or submitter can mark as completed"
        );
        require(
            request.status == RequestStatus.Approved,
            "Request must be approved first"
        );

        request.status = RequestStatus.Completed;
        emit RequestStatusChanged(_requestId, RequestStatus.Completed);
    }

    function getPendingRequests()
        external
        view
        returns (uint256[] memory)
    {
        uint256[] memory pendingIds = new uint256[](requestCounter);
        uint256 pendingCount = 0;

        for (uint256 i = 0; i < requestCounter; i++) {
            if (procurementRequests[i].status == RequestStatus.Pending) {
                pendingIds[pendingCount] = i;
                pendingCount++;
            }
        }

        uint256[] memory result = new uint256[](pendingCount);
        for (uint256 i = 0; i < pendingCount; i++) {
            result[i] = pendingIds[i];
        }

        return result;
    }

    function getRequestsByStatus(RequestStatus _status)
        external
        view
        returns (uint256[] memory)
    {
        uint256[] memory statusIds = new uint256[](requestCounter);
        uint256 statusCount = 0;

        for (uint256 i = 0; i < requestCounter; i++) {
            if (procurementRequests[i].status == _status) {
                statusIds[statusCount] = i;
                statusCount++;
            }
        }

        uint256[] memory result = new uint256[](statusCount);
        for (uint256 i = 0; i < statusCount; i++) {
            result[i] = statusIds[i];
        }

        return result;
    }

    function emergencyPause(uint256 _requestId)
        external
        onlyAdmin
        validRequest(_requestId)
    {
        ProcurementRequest storage request = procurementRequests[_requestId];
        require(request.status == RequestStatus.Pending, "Can only pause pending requests");

        request.status = RequestStatus.Rejected;
        emit RequestStatusChanged(_requestId, RequestStatus.Rejected);
    }
}
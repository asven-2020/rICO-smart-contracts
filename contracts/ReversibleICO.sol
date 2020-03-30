/*
 * source       https://github.com/lukso-network/rICO-smart-contracts
 * @name        rICO
 * @package     rICO-smart-contracts
 * @author      Micky Socaci <micky@binarzone.com>, Fabian Vogelsteller <@frozeman>
 * @license     MIT
 */

pragma solidity ^0.5.0;

import "./zeppelin/math/SafeMath.sol";
import "./zeppelin/token/ERC777/IERC777.sol";
import "./zeppelin/token/ERC777/IERC777Recipient.sol";
import "./zeppelin/introspection/IERC1820Registry.sol";

contract ReversibleICO is IERC777Recipient {


    /*
     *   Instances
     */
    using SafeMath for uint256;

    /// @dev The address of the introspection registry contract deployed.
    IERC1820Registry private _erc1820 = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);
    bytes32 constant private TOKENS_RECIPIENT_INTERFACE_HASH = keccak256("ERC777TokensRecipient");


    /*
     *   Contract States
     */
    /// @dev It is set to TRUE after the deployer initializes the contract.
    bool public initialized; // default: false

    /// @dev The contract can be automatically frozen in case of inconsistencies.
    bool public frozen; // default: false


    /*
     *   Addresses
     */
    /// @dev Only the deployer is allowed to initialize the contract.
    address public deployerAddress;
    /// @dev The actual rICO token contract address.
    address public tokenContractAddress;
    /// @dev The address of wallet of the project running the rICO.
    address public projectWalletAddress;
    /// @dev Only the whitelist controller can whitelist addresses.
    address public whitelistControllerAddress;


    /*
     *   Public Variables
     */
    /// @dev Accumulated amount tokens sent to the rICO by the projectWallet.
    uint256 public tokenSupply; // default: 0
    /// @dev Total amount of ETH currently accepted as a commitment to buy tokens (excluding pending).
    uint256 public committedETH; // default: 0
    /// @dev Accumulated amount of ETH received by the smart contract.
    uint256 public totalSentETH; // default: 0
    /// @dev Accumulated amount of ETH returned from canceled pending ETH.
    uint256 public canceledETH; // default: 0
    /// @dev Accumulated amount of ETH withdrawn by participants.
    uint256 public withdrawnETH; // default: 0
    /// @dev Count of the number the project has withdrawn from the funds raised.
    uint256 public projectWithdrawCount; // default: 0
    /// @dev Total amount of ETH withdrawn by the project
    uint256 public projectWithdrawnETH; // default: 0
    /// @dev Total amount allocated to the project by participants for the amount they withdrew.
    uint256 public projectAllocatedETH; // default: 0
    /// @dev Last block since the project has withdrawn. TODO remove?
//    uint256 public projectWithdrawnBlock; // default: 0

    /// @dev Minimum amount of ETH accepted for a contribution.
    /// @dev Everything lower than that will trigger a canceling of pending ETH.
    uint256 public minContribution = 0.001 ether;


    /*
     *   Commit phase (Stage 0)
     */
    /// @dev Initial token price in the commit phase (Stage 0).
    uint256 public commitPhasePrice;
    /// @dev Block number that indicates the start of the commit phase.
    uint256 public commitPhaseStartBlock;
    /// @dev Block number that indicates the end of the commit phase.
    uint256 public commitPhaseEndBlock;
    /// @dev The duration of the commit phase in blocks.
    uint256 public commitPhaseBlockCount;


    /*
     *   Buy phases (Stages 1-n)
     */
    /// @dev Block number that indicates the start of the buy phase (Stages 1-n).
    uint256 public buyPhaseStartBlock;
    /// @dev Block number that indicates the end of the buy phase.
    uint256 public buyPhaseEndBlock;
    /// @dev The duration of the buy phase in blocks.
    uint256 public buyPhaseBlockCount;


    /*
     *   Stages
     *   Stage 0 = commit phase
     *   Stage 1-n = buy phase
     */
    struct Stage {
        uint128 startBlock;
        uint128 endBlock;
        uint256 tokenPrice;
    }

    mapping(uint8 => Stage) public stages;
    uint8 public stageCount;
    uint256 public stageBlockCount;

    uint256 public DEBUG1 = 9999;
    uint256 public DEBUG2 = 9999;
    uint256 public DEBUG3 = 9999;
    uint256 public DEBUG4 = 9999;

    /*
     * Participants
     */
    struct Participant {
        bool whitelisted;
        uint32 contributions;
        mapping(uint8 => ParticipantStageDetails) byStage;
    }

    struct ParticipantDetails {
        uint256 NEWtotalReservedTokens; // unecessary?
        uint256 NEWcurrentReservedTokens;
//        uint256 NEWunlockedTokens; // NEEDED?
        uint256 NEWpendingEth;
//        uint256 NEWcommittedEth;
        uint256 NEWlastBlock;
    }
    
    struct ParticipantStageDetails {
        uint256 NEWcurrentReservedTokens;
        uint256 NEWpendingEth;
    }

    /// @dev Maps participants aggregated (i.e. all stages) stats by their address.
    mapping(address => ParticipantDetails) public participantAggregatedStats;
    /// @dev Maps participants stage stats by their address.
    mapping(address => Participant) public participantsByAddress;
    /// @dev Maps participants address to a unique participant ID (incremental IDs, based on "participantCount").
    mapping(uint256 => address) public participantsById;
    /// @dev Total number of rICO participants.
    uint256 public participantCount;


    /*
     * Events
     */
    enum ApplicationEventTypes {
        NOT_SET, // 0; will match default value of a mapping result
        CONTRIBUTION_NEW, // 1
        CONTRIBUTION_CANCEL, // 2
        PARTICIPANT_CANCEL, // 3
        COMMITMENT_ACCEPTED, // 4
        WHITELIST_APPROVE, // 5
        WHITELIST_REJECT, // 6
        PROJECT_WITHDRAW // 7
    }

    event ApplicationEvent (
        uint8 indexed _type,
        uint32 indexed _id,
        address indexed _address,
        uint256 _value
    );

    enum TransferTypes {
        NOT_SET, // 0
        AUTOMATIC_RETURN, // 1
        WHITELIST_REJECT, // 2
        PARTICIPANT_CANCEL, // 3
        PARTICIPANT_WITHDRAW, // 4
        PROJECT_WITHDRAW // 5
    }

    event TransferEvent (
        uint8 indexed _type,
        address indexed _address,
        uint256 indexed _value
    );


    // ------------------------------------------------------------------------------------------------

    /// @notice Constructor sets the deployer and defines ERC777TokensRecipient interface support.
    constructor() public {
        deployerAddress = msg.sender;
        _erc1820.setInterfaceImplementer(address(this), TOKENS_RECIPIENT_INTERFACE_HASH, address(this));
    }

    /**
     * @notice Initializes the contract. Only the deployer (set in the constructor) can call this method.
     * @param _tokenContractAddress The address of the ERC777 rICO token contract.
     * @param _whitelistControllerAddress The address of the controller handling whitelisting.
     * @param _projectWalletAddress The project wallet that can withdraw the contributions.
     * @param _commitPhaseStartBlock The block in which the commit phase starts.
     * @param _commitPhaseBlockCount The duration of the commit phase in blocks.
     * @param _commitPhasePrice The initial token price (in wei) during the commit phase.
     * @param _stageCount The number of the rICO stages.
     * @param _stageBlockCount The duration of each stage in blocks.
     * @param _stagePriceIncrease A factor used to increase the token price at each subsequent stage.
     */
    function init(
        address _tokenContractAddress,
        address _whitelistControllerAddress,
        address _projectWalletAddress,
        uint256 _commitPhaseStartBlock,
        uint256 _commitPhaseBlockCount,
        uint256 _commitPhasePrice,
        uint8 _stageCount,
        uint256 _stageBlockCount,
        uint256 _stagePriceIncrease
    )
    public
    onlyDeployer
    isNotInitialized
    {

        require(_commitPhaseStartBlock > getCurrentBlockNumber(), "Start block cannot be set in the past.");

        // Assign address variables
        tokenContractAddress = _tokenContractAddress;
        whitelistControllerAddress = _whitelistControllerAddress;
        projectWalletAddress = _projectWalletAddress;

        // UPDATE global STATS
        commitPhaseStartBlock = _commitPhaseStartBlock;
        commitPhaseBlockCount = _commitPhaseBlockCount;
        commitPhaseEndBlock = _commitPhaseStartBlock.add(_commitPhaseBlockCount).sub(1);
        commitPhasePrice = _commitPhasePrice;

        stageBlockCount = _stageBlockCount;
        stageCount = _stageCount;

        // Setup stage 0: The commit phase.
        Stage storage commitPhase = stages[0];

        commitPhase.startBlock = uint128(_commitPhaseStartBlock);
        commitPhase.endBlock = uint128(commitPhaseEndBlock);
        commitPhase.tokenPrice = _commitPhasePrice;

        // Setup stage 1 to n: The buy phase stages
        // Each new stage starts after the previous phase's endBlock
        uint256 previousStageEndBlock = commitPhase.endBlock;

        // Update stages: start, end, price
        for (uint8 i = 1; i <= _stageCount; i++) {
            // Get i-th stage
            Stage storage stageN = stages[i];
            // Start block is previous phase end block + 1, e.g. previous stage end=0, start=1;
            stageN.startBlock = uint128(previousStageEndBlock.add(1));
            // End block is previous phase end block + stage duration e.g. start=1, duration=10, end=0+10=10;
            stageN.endBlock = uint128(previousStageEndBlock.add(_stageBlockCount));
            // Store the current stage endBlock in order to update the next one
            previousStageEndBlock = stageN.endBlock;
            // At each stage the token price increases by _stagePriceIncrease * stageCount
            stageN.tokenPrice = _commitPhasePrice.add(_stagePriceIncrease.mul(i));
        }

        // UPDATE global STATS
        // The buy phase starts on the subsequent block of the commitPhase's (stage0) endBlock
        buyPhaseStartBlock = commitPhaseEndBlock.add(1);
        // The buy phase ends when the lat stage ends
        buyPhaseEndBlock = previousStageEndBlock;
        // The duration of buyPhase in blocks
        buyPhaseBlockCount = buyPhaseEndBlock.sub(buyPhaseStartBlock).add(1);

        // UPDATE global stats
//        projectWithdrawnBlock = buyPhaseStartBlock;

        // The contract is now initialized
        initialized = true;
    }


    /*
     * Public functions
     * The main way to interact with the rICO.
     */

    /**
     * @notice FALLBACK function: depending on the amount received it commits or it cancels contributions.
     */
    function()
    external
    payable
    {
        // Accept contributions higher than the minimum amount
        if (msg.value >= minContribution) {
            commit(msg.sender, msg.value);
        } else {
            // Participant cancels commitment during commit phase (Stage 0) OR if they've not been whitelisted yet.
            // This also allows for extended wallet compatibility by sending a non-zereo amount
            cancel(msg.sender, msg.value);
        }
    }

    /**
     * @notice ERC777TokensRecipient implementation for receiving ERC777 tokens.
     * @param _from Token sender.
     * @param _amount Token amount.
     */
    function tokensReceived(
        address,
        address _from,
        address,
        uint256 _amount,
        bytes calldata,
        bytes calldata
    )
    external
    isInitialized
        // isNotFrozen TODO??
        // requireNotEnded
    {
        // rICO should only receive tokens from the rICO Token Tracker.
        // Transactions from any other sender should revert
        require(msg.sender == tokenContractAddress, "Invalid token sent.");

        // two cases:
        // 1 - project wallet adds tokens to the sale
        if (_from == projectWalletAddress) {
            // Save the token amount allocated to the rICO address
            tokenSupply += _amount;
            return;

        // 2 - rICO contributor sends tokens back
        } else {
            withdraw(_from, _amount);
        }
    }


    /**
     * @notice External wrapper for commit() so that a participant can call it directly.
     */
    function commit()
    public
    payable
    {
        // Reject contributions lower than the minimum amount
        require(msg.value >= minContribution, "Value sent is less than minimum contribution.");
        // Call internal commit() for processing the contribution
        commit(msg.sender, msg.value);
    }


    /**
     * @notice Commits a participant's ETH.
     */
    function commit(address _sender, uint256 _value)
    internal
    isInitialized
    isNotFrozen
    isRunning
    {

        // UPDATE global STATS
        totalSentETH = totalSentETH.add(_value);

        // Participant initial state record
        Participant storage participantRecord = participantsByAddress[_sender];

        // Check if participant already exists
        if (participantRecord.contributions == 0) {
            // Identify the participants by their Id
            participantsById[participantCount] = _sender;
            // Increase participant count
            participantCount++;
        }

        // Record contribution into current stage totals for the participant
        addPendingContribution(_sender, _value);

        // If whitelisted, process the contribution automatically
        if (participantRecord.whitelisted == true) {
            acceptContributionsForAddress(_sender, uint8(ApplicationEventTypes.COMMITMENT_ACCEPTED));
        }
    }

    /**
     * @notice External wrapper for cancel() so that a participant can call it directly.
     */
    function cancel()
    public
    payable
    {
        // Call internal cancel() for processing the request
        cancel(msg.sender, msg.value);
    }

    /**
     * @notice Cancels non-whitelisted participant's pending ETH commitment.
     */
    function cancel(address _sender, uint256 _value)
    internal
    isInitialized
    isNotFrozen
    isRunning
    {
        // Participant must have pending ETH ...
        require(hasPendingETH(_sender), "cancel: Participant has no pending contributions.");

        // Cancel participant's contribution.
        cancelContributionsForAddress(_sender, _value, uint8(ApplicationEventTypes.PARTICIPANT_CANCEL));
    }


    /**
     * @notice Approves or rejects participants.
     * @param _addresses The list of participant address.
     * @param _approve Indicates if the provided participants are approved (true) or rejected (false).
     */
    function whitelist(address[] calldata _addresses, bool _approve)
    external
    isInitialized
    isNotFrozen
    onlyWhitelistController
    {
        // Revert if the provided list is empty
        require(_addresses.length > 0, "Empty list.");
        for (uint256 i = 0; i < _addresses.length; i++) {

            Participant storage participantRecord = participantsByAddress[_addresses[i]];

            if (_approve) {
                // Check if participant is already in the whitelist (e.g. duplicate list entry)
                if (!participantRecord.whitelisted) {
                    // If participants are approved: whitelist them and accept their contributions
                    participantRecord.whitelisted = true;
                    acceptContributionsForAddress(_addresses[i], uint8(ApplicationEventTypes.WHITELIST_APPROVE));
                }
            } else {
                // Decline participant and cancel their contributions, if they have pending ETH.
                if (hasPendingETH(_addresses[i])) {
                    cancelContributionsForAddress(_addresses[i], 0, uint8(ApplicationEventTypes.WHITELIST_REJECT));
                }
                participantRecord.whitelisted = false;
            }
        }
    }

    /**
     * @notice Allows for the project to withdraw ETH.
     * @param _ethAmount The ETH amount in wei.
     */
    function projectWithdraw(uint256 _ethAmount)
    external
    isInitialized
    {
        require(msg.sender == projectWalletAddress, "Only project wallet address.");

        // Get current allocated ETH to the project
        uint256 availableForWithdraw = getUnlockedProjectETH();

        require(_ethAmount <= availableForWithdraw, "Requested amount too big, not enough unlocked ETH available.");

        // UPDATE global STATS
        projectWithdrawCount++;
        projectWithdrawnETH = projectWithdrawnETH.add(_ethAmount);
        //        projectWithdrawnBlock = getCurrentBlockNumber();

        // Transfer ETH to project wallet
        address(uint160(projectWalletAddress)).transfer(_ethAmount);

        // Event emission
        emit ApplicationEvent(
            uint8(ApplicationEventTypes.PROJECT_WITHDRAW),
            uint32(projectWithdrawCount),
            projectWalletAddress,
            _ethAmount
        );
        emit TransferEvent(
            uint8(TransferTypes.PROJECT_WITHDRAW),
            projectWalletAddress,
            _ethAmount
        );
    }

    // ------------------------------------------------------------------------------------------------

    /*
     * Public view functions
     */

    /**
     * @notice Returns TRUE if the participant is whitelisted, otherwise FALSE.
     * @param _address the participant's address.
     * @return Boolean
     */
    function isWhitelisted(address _address) public view returns (bool) {
        return participantsByAddress[_address].whitelisted;
    }

    /**
     * @notice Returns project's current available ETH and unlocked ETH amount.
     * @return uint256 The unlocked amount available to the project for withdraw.
     */
    function getUnlockedProjectETH() public view returns (uint256) {

        // allocate ETH to projectAllocatedETH on contribution and withdraw
        // (take committedETH - any allocation by anyone) * global percentage = newly available for withdraw
        // any allocation by anyone += add newly available for withdraw

        // any allocation by anyone - has withdrawn already = total available for withdraw
        // has withdrawn already = has withdrawn already + new withdraw

        return committedETH.mul(
            getGlobalUnlockRatio(
                getCurrentBlockNumber(),
                buyPhaseStartBlock,
                buyPhaseEndBlock
            )
        ).div(10 ** 20)
        .add(projectAllocatedETH) // re-add the allocated amount back
        .sub(projectWithdrawnETH);
    }

    /*
        TODO?
        Do we want to normalise for gas usage ?!
        ( ie. add useless computation just to have the same gas used at all times ? )

        22023 - Case 1: lower than commit phase end
        22797 - Case 2: lower than stage[X].endBlock
        22813 - Case 3: exactly at stage[X].endBlock

        Doing an iteration and validating on each item range can go up to 37391 gas for 13 stages.
    */
    /**
     * @notice Returns the current stage at the current block number.
     */
    function getCurrentStage() public view returns (uint8) {
        return getStageAtBlock(getCurrentBlockNumber());
    }

    /**
     * @notice Returns the current token price at the current block number.
     */
    function getCurrentPrice() public view returns (uint256) {
        return getPriceAtBlock(getCurrentBlockNumber());
    }

    /**
     * @notice Returns the token price at the specified block height.
     * @param _blockNumber the block height at which we want to retrieve the token price.
     */
    function getPriceAtBlock(uint256 _blockNumber) public view returns (uint256) {
        // first retrieve the stage that the block belongs to
        uint8 stage = getStageAtBlock(_blockNumber);
        if (stage <= stageCount) {
            return stages[stage].tokenPrice;
        }
        // revert with stage not found?
        return 0;
    }

    /**
     * @notice Returns the amount of tokens that ETH would buy at a specific stage.
     * @param _ethValue The ETH amount in wei.
     * @param _stageId The stage we are interested in.
     */
    function getTokenAmountForEthAtStage(uint256 _ethValue, uint8 _stageId) public view returns (uint256) {
        // Since our tokens cost less than 1 eth, and decimals are 18
        // 1 wei will always buy something.

        // add token decimals to value before division, that way we increase precision.
        // return (_ethValue * (10 ** 18)) / Stages[_stageId].token_price;
        return _ethValue.mul(
            (10 ** 18)
        ).div(stages[_stageId].tokenPrice);
    }

    /**
     * @notice Returns the amount of ETH (in wei) that tokens are worth at a specified stage.
     * @param _tokenAmount The amount of token.
     * @param _stageId The stage we are interested in.
     */
    function getEthAmountForTokensAtStage(uint256 _tokenAmount, uint8 _stageId) public view returns (uint256) {
        // return (_token_amount * Stages[_stageId].token_price) / (10 ** 18);
        return _tokenAmount.mul(
            stages[_stageId].tokenPrice
        ).div(
            (10 ** 18)
        );
    }

    /*
     * Participant view functions
     */

    /**
    * @notice Returns the participants current pending total ETH amount
    * @param _participantAddress The participant's address.
    */
    function getParticipantPendingETH(address _participantAddress) public view returns (uint256) {
        ParticipantDetails storage participantStats = participantAggregatedStats[_participantAddress];

        return participantStats.NEWpendingEth;
    }

    /**
     * @notice Returns participant's stats by stage.
     * @param _address The participant's address.
     * @param _stageId The relevant stage.

     * @dev Direct call: participantsByAddress[_address].byStage[_stageId]._accepted
     */
    function getParticipantDetailsByStage(address _address, uint8 _stageId) public view
    returns (
        uint256 NEWcurrentReservedTokens,
        uint256 NEWpendingEth
    ) {

        ParticipantStageDetails storage totalsRecord = participantsByAddress[_address].byStage[_stageId];
        return (
        totalsRecord.NEWcurrentReservedTokens,
        totalsRecord.NEWpendingEth
        );
    }


    /**
     * @notice Returns the cancel modes for a participant.
     * @param _participantAddress The participant's address.
     * @return byEth Boolean
     * @return byTokens Boolean
     */
    function getCancelModes(address _participantAddress) external view returns (bool byEth, bool byTokens) {

        // byEth remains false as they need to send tokens back.
        byTokens = canWithdraw(_participantAddress);
        // byTokens remains false as the participant should have no tokens to send back anyway.
        byEth = hasPendingETH(_participantAddress);
    }

    /**
     * @notice Returns TRUE if the participant has locked tokens in the current stage.
     * @param _participantAddress The participant's address.
     */
    function canWithdraw(address _participantAddress) public view returns (bool) {
        if (getReservedTokenAmount(_participantAddress) > 0) {
            return true;
        }
        return false;
    }

    /**
     * @notice Returns TRUE if participant has pending ETH and is not whitelisted.
     * @param _participantAddress The participant's address.
     */
    function hasPendingETH(address _participantAddress) public view returns (bool) {
        if (getParticipantPendingETH(_participantAddress) > 0) {
            return true;
        }
        return false;
    }

    // ------------------------------------------------------------------------------------------------

    /*
     * Helper public view functions
     */

    /**
     * @notice Returns the current block number: required in order to override when running tests.
     */
    function getCurrentBlockNumber() public view returns (uint256) {
        return block.number;
    }

    /**
     * @notice Returns the stage which a given block belongs to.
     * @param _blockNumber The block number.
     */
    function getStageAtBlock(uint256 _blockNumber) public view returns (uint8) {

        // *NOTE: if selectedBlock is end block.. the participant will get the correct
        //        stage now but their new transaction will end up in the
        //        next block which changes the stage vs what they've seen..
        //        resulting in a different purchase price.
        //
        // @TODO: decide how we want to handle this on the frontend,
        //        contract should always display proper data.
        //

        require(_blockNumber >= commitPhaseStartBlock && _blockNumber <= buyPhaseEndBlock, "Block outside of rICO period.");

        // Return commit phase (stage 0)
        if (_blockNumber <= commitPhaseEndBlock) {
            return 0;
        }

        // This is the number of blocks starting from the first stage.
        uint256 distance = _blockNumber - (commitPhaseEndBlock + 1);
        // Get the stageId (1..stageCount), commitPhase is stage 0
        // e.g. distance = 5, stageBlockCount = 5, stageID = 2
        uint256 stageID = 1 + (distance / stageBlockCount);

        return uint8(stageID);
    }


    /**
     * @notice Returns the contract's available ETH to commit at a certain stage.
     * @param _stage the stage id.
     * TODO we use such functions in the main commit calculations, are there chances of rounding errors?
     */
    function availableEthAtStage(uint8 _stage) public view returns (uint256) {
        // Multiply the number of tokens held by the contract with the token price
        // at the specified stage and perform precision adjustments(div).
        return IERC777(tokenContractAddress).balanceOf(address(this)).mul(
            stages[_stage].tokenPrice
        ).div(10 ** 18); // should we use 10 ** 20?
    }

    /**
     * @notice Calculates the percentage of bought tokens (or ETH allocated to the project) beginning from the buy phase start to the current block.
     * @return Unlock percentage multiplied by 10 to the power of precision. (should be 20 resulting in 10 ** 20, so we can divide by 100 later and get 18 decimals).
     */
    function calcUnlockRatio(
        uint256 _amount,
        uint256 _lastBlock
    ) public view returns (uint256) {
        uint8 precision = 20;
        uint256 currentBlock = getCurrentBlockNumber();

        if(_lastBlock == 0) {
            _lastBlock = buyPhaseStartBlock;
        }

        if(_amount == 0) {
            return 0;
        }

        // Calculate WITHING the buy phase
        if (currentBlock >= _lastBlock && currentBlock <= buyPhaseEndBlock) {
            // number of blocks ( ie: start=5/end=10 => 10 - 5 + 1 => 6 )
            uint256 totalBlockCount = buyPhaseEndBlock.sub(_lastBlock).add(1);

            // get the number of blocks that have "elapsed" since the start block
            // add 1 since start block needs to return higher than 0
            uint256 passedBlocks = currentBlock.sub(_lastBlock).add(1);

            return _amount.mul(
                passedBlocks.mul(10 ** uint256(precision))
                .div(totalBlockCount)).div(10 ** uint256(precision));

        // Return everything AFTER the buy phase
        } else if (currentBlock > buyPhaseEndBlock) {
            return _amount;

        // Return nothing BEFORE the buy phase
        } else {
            return 0;
        }
    }

    /**
     * @notice Calculates the percentage of bought tokens (or ETH allocated to the project) beginning from the buy phase start to the current block.
     * @return Unlock percentage multiplied by 10 to the power of precision. (should be 20 resulting in 10 ** 20, so we can divide by 100 later and get 18 decimals).
     TODO remove
     */
    function getGlobalUnlockRatio(
        uint256 _currentBlock,
        uint256 _startBlock,
        uint256 _endBlock
    ) public pure returns (uint256) {
        uint8 precision = 20;
        if (_currentBlock >= _startBlock && _currentBlock <= _endBlock) {
            // number of blocks ( ie: start=5/end=10 => 10 - 5 + 1 => 6 )
            uint256 totalBlockCount = _endBlock.sub(_startBlock).add(1);

            // get the number of blocks that have "elapsed" since the start block
            // add 1 since start block needs to return higher than 0
            uint256 passedBlocks = _currentBlock.sub(_startBlock).add(1);

            return passedBlocks.mul(
                10 ** uint256(precision)
            ).div(totalBlockCount);
        } else if (_currentBlock > _endBlock) {
            return 10 ** uint256(precision);
        } else {
            return 0;
        }
    }

    // TODO remove
    function getCurrentGlobalUnlockRatio() public view returns (uint256) {
        return getGlobalUnlockRatio(
            getCurrentBlockNumber(),
            buyPhaseStartBlock,
            buyPhaseEndBlock
        );
    }


    /**
     * @notice Returns the participant's amount of locked tokens at the current block.
     * @param _participantAddress The participant's address.
     */
    function getReservedTokenAmount(address _participantAddress) public view returns (uint256) {
        ParticipantDetails storage participantStats = participantAggregatedStats[_participantAddress];

        if(participantStats.NEWcurrentReservedTokens == 0) {
            return 0;
        }

        return participantStats.NEWcurrentReservedTokens.sub(
            calcUnlockRatio(participantStats.NEWcurrentReservedTokens, participantStats.NEWlastBlock)
        );
    }

    /**
     * @notice Returns the participant's amount of locked tokens at the current block.
     * @param _participantAddress The participant's address.
     // TODO needed? Also needs to add accumulated past locked tokens
     */
    function getUnlockedTokenAmount(address _participantAddress) public view returns (uint256) {
        ParticipantDetails storage participantStats = participantAggregatedStats[_participantAddress];

        return calcUnlockRatio(participantStats.NEWcurrentReservedTokens, participantStats.NEWlastBlock);
        // + accumulated reserved token amounts, should we keep track of that?
    }


    // ------------------------------------------------------------------------------------------------

    /*
     * Internal functions
     */


    /**
     * @notice Allow a participant to withdraw by sending tokens back to rICO contract.
     * @param _participantAddress participant address.
     * @param _returnedTokenAmount The amount of tokens returned.
     */
    function withdraw(address _participantAddress, uint256 _returnedTokenAmount) internal {
        ParticipantDetails storage participantStats = participantAggregatedStats[_participantAddress];

        // UPDATE the locked/unlocked ratio for this participant
        participantStats.NEWcurrentReservedTokens = getReservedTokenAmount(_participantAddress);

        uint256 returnedTokenAmount = _returnedTokenAmount;
        uint256 overflowingTokenAmount;
        uint256 returnEthAmount;

        // Only allow reserved tokens be returned, return the overflow.
        if (returnedTokenAmount > participantStats.NEWcurrentReservedTokens) {
            overflowingTokenAmount = returnedTokenAmount.sub(participantStats.NEWcurrentReservedTokens);
            returnedTokenAmount = participantStats.NEWcurrentReservedTokens;
        }

        // -> RETURN ETH for TOKENS
        // RETURNS LAST STAGES LOCKED TOKENS FIRST (HIGHEST PRICED TOKENS)
        for (uint8 stageId = getCurrentStage(); stageId >= 0; stageId--) {
            ParticipantStageDetails storage byStage = participantsByAddress[_participantAddress].byStage[stageId];


            // cancel if all is accounted for
            if(returnedTokenAmount == 0) {
                break;
            }

            uint256 processTokens = byStage.NEWcurrentReservedTokens;

            // reduce the process tokens in this stage by whats currently still locked
//            processTokens = processTokens.sub(calcUnlockRatio(processTokens, participantStats.NEWlastBlock));

            if (returnedTokenAmount < processTokens) {
                processTokens = returnedTokenAmount;
            }

            // get ETH amount for tokens
            returnEthAmount = returnEthAmount.add(getEthAmountForTokensAtStage(processTokens, stageId));

            // UPDATE participantStats
            byStage.NEWcurrentReservedTokens = byStage.NEWcurrentReservedTokens.sub(processTokens);
            participantStats.NEWcurrentReservedTokens = participantStats.NEWcurrentReservedTokens.sub(processTokens);

            // reduce processed token amount from returned token amount
            returnedTokenAmount = returnedTokenAmount.sub(processTokens);
        }


        // UPDATE global STATS
        withdrawnETH = withdrawnETH.add(returnEthAmount);
        committedETH = committedETH.sub(returnEthAmount);

        // RESET BLOCKNUMBER: Reset the ratio calculations to start from this point in time.
        participantStats.NEWlastBlock = getCurrentBlockNumber();


        // Return overflowing tokens received
        if (overflowingTokenAmount > 0) {
            // send tokens back to participant
            bytes memory data;
            // solium-disable-next-line security/no-send
            IERC777(tokenContractAddress).send(_participantAddress, overflowingTokenAmount, data);
        }

        // Return ETH back to participant
        address(uint160(_participantAddress)).transfer(returnEthAmount);
        emit TransferEvent(uint8(TransferTypes.PARTICIPANT_WITHDRAW), _participantAddress, returnEthAmount);
    }


    /**
     * @notice Records a new contribution.
     * @param _from Participant's address.
     * @param _receivedValue The amount contributed.
     */
    function addPendingContribution(address _from, uint256 _receivedValue) private {

        uint8 currentStage = getCurrentStage();

        Participant storage participantRecord = participantsByAddress[_from];
        ParticipantDetails storage participantStats = participantAggregatedStats[_from];
        ParticipantStageDetails storage byStage = participantRecord.byStage[currentStage];

        // UPDATE STATS
        participantRecord.contributions++;
        byStage.NEWpendingEth = byStage.NEWpendingEth.add(_receivedValue);
        participantStats.NEWpendingEth = participantStats.NEWpendingEth.add(_receivedValue);

        emit ApplicationEvent(
            uint8(ApplicationEventTypes.CONTRIBUTION_NEW),
            uint32(participantRecord.contributions),
            _from,
            _receivedValue
        );
    }


    /**
    * @notice Accept a participant's contribution.
    * @param _participantAddress Participant's address.
    * @param _eventType Can be either WHITELIST_APPROVE or COMMITMENT_ACCEPTED.
    */
    function acceptContributionsForAddress(address _participantAddress, uint8 _eventType) internal {

        // stop if no ETH are pending
        if (participantAggregatedStats[_participantAddress].NEWpendingEth == 0) {
            return;
        }

        ParticipantDetails storage participantStats = participantAggregatedStats[_participantAddress];

        // UPDATE the locked/unlocked ratio for this participant
        participantStats.NEWcurrentReservedTokens = getReservedTokenAmount(_participantAddress);

        // RESET BLOCKNUMBER: Reset the ratio calculations to start from this point in time.
        participantStats.NEWlastBlock = getCurrentBlockNumber();

        uint8 currentStage = getCurrentStage();
        uint256 totalReturnETH;

        // Iterate over all stages and their pending contributions
        for (uint8 stageId = 0; stageId <= currentStage; stageId++) {
            ParticipantStageDetails storage byStage = participantsByAddress[_participantAddress].byStage[stageId];

            uint256 maxAvailableEth = availableEthAtStage(currentStage);
            uint256 pendingEth = byStage.NEWpendingEth;
            uint256 returnEth = 0;

            // skip if not ETH is pending
            if (pendingEth == 0) {
                continue;
            }


            // if incoming value is higher than what we can accept,
            // just accept the difference and return the rest
            if (pendingEth > maxAvailableEth) {
                returnEth = pendingEth.sub(maxAvailableEth);
                pendingEth = maxAvailableEth;

                totalReturnETH = totalReturnETH.add(returnEth);
            }

            // convert ETH to TOKENS
            uint256 newTokenAmount = getTokenAmountForEthAtStage(
                pendingEth, stageId
            );

            byStage.NEWcurrentReservedTokens = byStage.NEWcurrentReservedTokens.add(newTokenAmount);
            byStage.NEWpendingEth = byStage.NEWpendingEth.sub(pendingEth).sub(returnEth);

            participantStats.NEWcurrentReservedTokens = participantStats.NEWcurrentReservedTokens.add(newTokenAmount);
            participantStats.NEWpendingEth = participantStats.NEWpendingEth.sub(pendingEth).sub(returnEth);

            committedETH = committedETH.add(pendingEth);


            // Transfer tokens to the participant
            // TODO AUDIT: as this is in a loop, can it create a recursive situation for the next stages?
            // solium-disable-next-line security/no-send
            IERC777(tokenContractAddress).send(_participantAddress, newTokenAmount, "");
            emit ApplicationEvent(_eventType, uint32(stageId), _participantAddress, pendingEth);
        }

        // Return what couldn't be accepted
        if (totalReturnETH > 0) {

            // UPDATE global STATS
            withdrawnETH = withdrawnETH.add(totalReturnETH);

            address(uint160(_participantAddress)).transfer(totalReturnETH);
            emit TransferEvent(uint8(TransferTypes.AUTOMATIC_RETURN), _participantAddress, totalReturnETH);
        }

    }

    /**
     * @notice Cancels all of the participant's contributions so far.
     * @param _from Participant's address
     * @param _value the ETH amount sent with the transaction, to return
     * @param _eventType Reason for canceling: {WHITELIST_REJECT, PARTICIPANT_CANCEL}
     * TODO add whitelisted modifier, on all functions that require such
     */
    function cancelContributionsForAddress(address _from, uint256 _value, uint8 _eventType) internal {
        Participant storage participantRecord = participantsByAddress[_from];
        uint256 allPendingEth = getParticipantPendingETH(_from);

        // Revert if there is no pending ETH contribution
        require(allPendingEth > 0, "Participant has no contributions to cancel.");

        // UPDATE global STATS
        canceledETH = canceledETH.add(allPendingEth);

        // Update stages
        uint8 currentStage = getCurrentStage();
        for (uint8 stageId = 0; stageId <= currentStage; stageId++) {
            ParticipantStageDetails storage byStage = participantRecord.byStage[stageId];

            byStage.NEWpendingEth = 0;
        }

        // transfer ETH back to participant including received value
        address(uint160(_from)).transfer(allPendingEth.add(_value));

        // event emission
        emit TransferEvent(_eventType, _from, allPendingEth);
        emit ApplicationEvent(
            _eventType,
            uint32(participantRecord.contributions),
            _from,
            allPendingEth
        );
    }


    /*
     *   Modifiers
     */

    /**
     * @notice Checks if the sender is the deployer.
     */
    modifier onlyDeployer() {
        require(msg.sender == deployerAddress, "Only the deployer can call this method.");
        _;
    }

    /**
     * @notice Checks if the sender is the whitelist controller.
     */
    modifier onlyWhitelistController() {
        require(msg.sender == whitelistControllerAddress, "Only the whitelist controller can call this method.");
        _;
    }

    /**
     * @notice Requires the contract to have been initialized.
     */
    modifier isInitialized() {
        require(initialized == true, "Contract must be initialized.");
        _;
    }

    /**
     * @notice Requires the contract to NOT have been initialized,
     */
    modifier isNotInitialized() {
        require(initialized == false, "Contract is already initialized.");
        _;
    }

    /**
     * @notice @dev Requires the contract to be not frozen.
     */
    modifier isNotFrozen() {
        require(frozen == false, "Contract can not be frozen.");
        _;
    }

    /**
     * @notice Checks if the rICO is running.
     */
    modifier isRunning() {
        uint256 blockNumber = getCurrentBlockNumber();
        require(blockNumber >= commitPhaseStartBlock && blockNumber <= buyPhaseEndBlock, "Contract outside buy in range");
        _;
    }

    // TODO remove?
    function uintToString(uint i) internal pure returns (string memory _uintAsString) {
        uint _i = i;
        if (_i == 0) {
            return "0";
        }
        uint j = _i;
        uint len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint k = len - 1;
        while (_i != 0) {
            bstr[k--] = byte(uint8(48 + _i % 10));
            _i /= 10;
        }
        return string(bstr);
    }
}

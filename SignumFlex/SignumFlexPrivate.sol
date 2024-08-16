// SPDX-License-Identifier: MIT
pragma solidity 0.8.3;

import "./interfaces/IERC20.sol";

interface IFactory {
    function stakeAmount() external view returns (uint256);
    function stakeLockTime() external view returns (uint256);
}

/*
 @author Avantgarde Blockchain Solutions.
 @title SignumFlex
 @dev This is a streamlined Signum oracle system which handles reporting,
 * slashing, and user data getters in one contract. This contract is controlled
 * by a single address known as 'governance', which could be an externally owned
 * account or a contract, allowing for a flexible, modular design.
*/
contract SignumFlexPrivate {
    // Storage
    IERC20 public immutable token = IERC20(0x113c82608A84bD47eE90a7A498b2663f3A7B977C); // token used for staking and rewards
    address public governance = 0x2124F2773425BCb252A495E446e6Cb738AAc57cd; // address with ability to remove values and slash reporters
    address public factory; // private signumFlex factory address.
    address public immutable owner; // contract deployer, can call init function once
    uint256 public toWithdraw; // amountLockedForWithdrawal
    address public governanceEscrow = 0x237a21b1bb4d0283c7590EA76e3Cc8B47985C9Ce; // wallet that will received tokens from slashed stake.
    uint256 public totalStakeAmount; // total amount of tokens locked in contract (via stake)
    uint256 public totalStakers; // total number of stakers with at least stakeAmount staked, not exact

    mapping(bytes32 => Report) private reports; // mapping of query IDs to a report
    mapping(address => ReporterInfo) private reporterDetails; // mapping from a persons address to their reporting info
    mapping(address => bool) public whitelist; // mapping to store the whitelist of addresses
    mapping(address => StakeInfo) private stakerDetails; // mapping from a persons address to their staking info


    // Structs
    struct Report {
        uint256[] timestamps; // array of all newValueTimestamps reported
        mapping(uint256 => uint256) timestampIndex; // mapping of timestamps to respective indices
        mapping(uint256 => bytes) valueByTimestamp; // mapping of timestamps to values
        mapping(uint256 => address) reporterByTimestamp; // mapping of timestamps to reporters
        mapping(uint256 => bool) isDisputed;
    }

    struct ReporterInfo {
        uint256 reportsSubmitted; // total number of reports submitted by reporter
    }

    struct StakeInfo {
        uint256 startDate; // stake or withdrawal request start date
        uint256 stakedBalance; // staked token balance
        uint256 lockedBalance; // amount locked for withdrawal
        uint256 reporterLastTimestamp; // timestamp of reporter's last reported value
        uint256 reportsSubmitted; // total number of reports submitted by reporter
        bytes32 reporterQueryId; // QueryId the reporter is reporting for
        bool staked; // used to keep track of total stakers
    }

    // Events
    event NewReport(
        bytes32 indexed _queryId,
        uint256 indexed _time,
        bytes _value,
        uint256 _nonce,
        bytes _queryData,
        address indexed _reporter
    );
    event ReporterSlashed(
        address indexed _reporter,
        address _recipient,
        uint256 _slashAmount
    );
    event ValueRemoved(bytes32 _queryId, uint256 _timestamp);
    event WhitelistUpdated(address indexed _reporter, bool _status);
    event NewStakeAmount(uint256 _newStakeAmount);
    event NewStaker(address indexed _staker, uint256 indexed _amount);
    event StakeWithdrawRequested(address _staker, uint256 _amount);
    event StakeWithdrawn(address _staker);

    // Functions
    /*
     * @dev Initializes system parameters
     * @param _token address of token used for rewards (if needed)
     */
    constructor(address _factory) {       
        owner = tx.origin;
        factory = _factory;
    }

    /*
     * @dev Allows the owner to add or remove reporters from the whitelist
     * @param _reporter address of the reporter
     * @param _queryId the queryId that this reporter will be reporting to. NOTE: the queryId for this reporter cannot be changed.
     * @param _status true to add, false to remove
     */
    function updateWhitelist(address _reporter, bytes32 _queryId, bool _status) external {
        require(msg.sender == owner, "only owner can update whitelist");
        whitelist[_reporter] = _status;

        if (stakerDetails[_reporter].reporterQueryId == 0) {
        stakerDetails[_reporter].reporterQueryId = _queryId;
        }

        emit WhitelistUpdated(_reporter, _status);
    }

    /*
     * @dev Removes a value from the oracle.
     * Note: this function is only callable by the Governance contract.
     * @param _queryId is ID of the specific data feed
     * @param _timestamp is the timestamp of the data value to remove
     */
    function removeValue(bytes32 _queryId, uint256 _timestamp) external {
        require(msg.sender == governance, "caller must be governance address");
        Report storage _report = reports[_queryId];
        require(!_report.isDisputed[_timestamp], "value already disputed");
        uint256 _index = _report.timestampIndex[_timestamp];
        require(_timestamp == _report.timestamps[_index], "invalid timestamp");
        _report.valueByTimestamp[_timestamp] = "";
        _report.isDisputed[_timestamp] = true;
        emit ValueRemoved(_queryId, _timestamp);
    }

    /*
     * @dev Slashes a reporter and transfers their stake amount to governance escrow
     * Note: this function is only callable by the governance address.
     * @param _reporter is the address of the reporter being slashed
     * @param _recipient is the address receiving the reporter's stake
     * @return _slashAmount uint256 amount of token slashed and sent to governance escrow address
     */
    function slashReporter(address _reporter)
        external
        returns (uint256 _slashAmount)
    {
        require(msg.sender == governance, "only governance can slash reporter");
        StakeInfo storage _staker = stakerDetails[_reporter];
        uint256 _stakedBalance = _staker.stakedBalance;
        uint256 _lockedBalance = _staker.lockedBalance;
        require(_stakedBalance + _lockedBalance > 0, "zero staker balance");
        if (_lockedBalance >= IFactory(factory).stakeAmount()) {
            // if locked balance is at least stakeAmount, slash from locked balance
            _slashAmount = IFactory(factory).stakeAmount();
            _staker.lockedBalance -= IFactory(factory).stakeAmount();
            toWithdraw -= IFactory(factory).stakeAmount();
        } else if (_lockedBalance + _stakedBalance >= IFactory(factory).stakeAmount()) {
            // if locked balance + staked balance is at least stakeAmount,
            // slash from locked balance and slash remainder from staked balance
            _slashAmount = IFactory(factory).stakeAmount();
            _updateStakeAndPayRewards(
                _reporter,
                _stakedBalance - (IFactory(factory).stakeAmount() - _lockedBalance)
            );
            toWithdraw -= _lockedBalance;
            _staker.lockedBalance = 0;
        } else {
            // if sum(locked balance + staked balance) is less than stakeAmount,
            // slash sum
            _slashAmount = _stakedBalance + _lockedBalance;
            toWithdraw -= _lockedBalance;
            _updateStakeAndPayRewards(_reporter, 0);
            _staker.lockedBalance = 0;
        }
        require(token.transfer(governanceEscrow, _slashAmount));
        emit ReporterSlashed(_reporter, governanceEscrow, _slashAmount);
    }

    /**
     * @dev Allows a reporter to submit stake
     * @param _amount amount of tokens to stake
     */
    function depositStake(uint256 _amount) external {
        require(governance != address(0), "governance address not set");
        StakeInfo storage _staker = stakerDetails[msg.sender];
        uint256 _stakedBalance = _staker.stakedBalance;
        uint256 _lockedBalance = _staker.lockedBalance;
        if (_lockedBalance > 0) {
            if (_lockedBalance >= _amount) {
                // if staker's locked balance covers full _amount, use that
                _staker.lockedBalance -= _amount;
                toWithdraw -= _amount;
            } else {
                // otherwise, stake the whole locked balance and transfer the
                // remaining amount from the staker's address
                require(
                    token.transferFrom(
                        msg.sender,
                        address(this),
                        _amount - _lockedBalance
                    )
                );
                toWithdraw -= _staker.lockedBalance;
                _staker.lockedBalance = 0;
            }
        } else {
            require(token.transferFrom(msg.sender, address(this), _amount));
        }
        _updateStakeAndPayRewards(msg.sender, _stakedBalance + _amount);
        _staker.startDate = block.timestamp; // This resets the staker start date to now
        emit NewStaker(msg.sender, _amount);
    }

    /**
     * @dev Allows a reporter to request to withdraw their stake
     * @param _amount amount of staked tokens requesting to withdraw
     */
    function requestStakingWithdraw(uint256 _amount) external {
        StakeInfo storage _staker = stakerDetails[msg.sender];
        require(
            _staker.stakedBalance >= _amount,
            "insufficient staked balance"
        );
        require(
            block.timestamp >= _staker.startDate + IFactory(factory).stakeLockTime(), 
            "You must wait for the stake lock time to pass before requesting stake withdraw."
        );
        _updateStakeAndPayRewards(msg.sender, _staker.stakedBalance - _amount);
        _staker.startDate = block.timestamp;
        _staker.lockedBalance += _amount;
        toWithdraw += _amount;
        emit StakeWithdrawRequested(msg.sender, _amount);
    }

    /**
     * @dev Withdraws a reporter's stake after the lock period expires
     */
    function withdrawStake() external {
        StakeInfo storage _staker = stakerDetails[msg.sender];
        // Ensure reporter is locked and that enough time has passed
        require(
            block.timestamp - _staker.startDate >= 7 days,
            "7 days didn't pass"
        );
        require(
            _staker.lockedBalance > 0,
            "reporter not locked for withdrawal"
        );
        require(token.transfer(msg.sender, _staker.lockedBalance));
        toWithdraw -= _staker.lockedBalance;
        _staker.lockedBalance = 0;
        emit StakeWithdrawn(msg.sender);
    }

    /*
     * @dev Allows a reporter to submit a value to the oracle
     * @param _queryId is ID of the specific data feed. Equals keccak256(_queryData) for non-legacy IDs
     * @param _value is the value the user submits to the oracle
     * @param _nonce is the current value count for the query id
     * @param _queryData is the data used to fulfill the data query
     */
    function submitValue(
        bytes32 _queryId,
        bytes calldata _value,
        uint256 _nonce,
        bytes calldata _queryData
    ) external {
        require(keccak256(_value) != keccak256(""), "value must be submitted");
        require(whitelist[msg.sender], "reporter not whitelisted");
        require(stakerDetails[msg.sender].stakedBalance >= IFactory(factory).stakeAmount(), "not enough tokens staked to submit value");
        require(_queryId == stakerDetails[msg.sender].reporterQueryId, "can only report for queryId set in whitelist function");
        Report storage _report = reports[_queryId];
        require(
            _nonce == _report.timestamps.length || _nonce == 0,
            "nonce must match timestamp index"
        );
        ReporterInfo storage _reporter = reporterDetails[msg.sender];
        require(
            _queryId == keccak256(_queryData),
            "query id must be hash of query data"
        );
        // Checks for no double reporting of timestamps
        require(
            _report.reporterByTimestamp[block.timestamp] == address(0),
            "timestamp already reported for"
        );
        // Update number of timestamps, value for given timestamp, and reporter for timestamp
        _report.timestampIndex[block.timestamp] = _report.timestamps.length;
        _report.timestamps.push(block.timestamp);
        _report.valueByTimestamp[block.timestamp] = _value;
        _report.reporterByTimestamp[block.timestamp] = msg.sender;
        // Update last oracle value and number of values submitted by a reporter
        unchecked {
            _reporter.reportsSubmitted++;
        }
        emit NewReport(
            _queryId,
            block.timestamp,
            _value,
            _nonce,
            _queryData,
            msg.sender
        );
    }

    // *****************************************************************************
    // *                                                                           *
    // *                               Getters                                     *
    // *                                                                           *
    // *****************************************************************************

    /*
     * @dev Returns the current value of a data feed given a specific ID
     * @param _queryId is the ID of the specific data feed
     * @return _value the latest submitted value for the given queryId
     */
    function getCurrentValue(bytes32 _queryId)
        external
        view
        returns (bytes memory _value)
    {
        bool _didGet;
        (_didGet, _value, ) = getDataBefore(_queryId, block.timestamp + 1);
        if(!_didGet){revert();}
    }

    /*
     * @dev Retrieves the latest value for the queryId before the specified timestamp
     * @param _queryId is the queryId to look up the value for
     * @param _timestamp before which to search for latest value
     * @return _ifRetrieve bool true if able to retrieve a non-zero value
     * @return _value the value retrieved
     * @return _timestampRetrieved the value's timestamp
     */
    function getDataBefore(bytes32 _queryId, uint256 _timestamp)
        public
        view
        returns (
            bool _ifRetrieve,
            bytes memory _value,
            uint256 _timestampRetrieved
        )
    {
        (bool _found, uint256 _index) = getIndexForDataBefore(
            _queryId,
            _timestamp
        );
        if (!_found) return (false, bytes(""), 0);
        _timestampRetrieved = getTimestampbyQueryIdandIndex(_queryId, _index);
        _value = retrieveData(_queryId, _timestampRetrieved);
        return (true, _value, _timestampRetrieved);
    }

    /*
     * @dev Returns governance address
     * @return address governance
     */
    function getGovernanceAddress() external view returns (address) {
        return governance;
    }

    /*
     * @dev Counts the number of values that have been submitted for the request.
     * @param _queryId the id to look up
     * @return uint256 count of the number of values received for the id
     */
    function getNewValueCountbyQueryId(bytes32 _queryId)
        public
        view
        returns (uint256)
    {
        return reports[_queryId].timestamps.length;
    }

    /*
     * @dev Returns reporter address and whether a value was removed for a given queryId and timestamp
     * @param _queryId the id to look up
     * @param _timestamp is the timestamp of the value to look up
     * @return address reporter who submitted the value
     * @return bool true if the value was removed
     */
    function getReportDetails(bytes32 _queryId, uint256 _timestamp)
        external
        view
        returns (address, bool)
    {
        return (reports[_queryId].reporterByTimestamp[_timestamp], reports[_queryId].isDisputed[_timestamp]);
    }

    /*
     * @dev Returns the address of the reporter who submitted a value for a data ID at a specific time
     * @param _queryId is ID of the specific data feed
     * @param _timestamp is the timestamp to find a corresponding reporter for
     * @return address of the reporter who reported the value for the data ID at the given timestamp
     */
    function getReporterByTimestamp(bytes32 _queryId, uint256 _timestamp)
        external
        view
        returns (address)
    {
        return reports[_queryId].reporterByTimestamp[_timestamp];
    }

    /*
     * @dev Returns the number of values submitted by a specific reporter address
     * @param _reporter is the address of a reporter
     * @return uint256 the number of values submitted by the given reporter
     */
    function getReportsSubmittedByAddress(address _reporter)
        external
        view
        returns (uint256)
    {
        return reporterDetails[_reporter].reportsSubmitted;
    }

    /*
     * @dev Returns whether a given value is disputed
     * @param _queryId unique ID of the data feed
     * @param _timestamp timestamp of the value
     * @return bool whether the value is disputed
     */
    function isInDispute(bytes32 _queryId, uint256 _timestamp)
        public
        view
        returns (bool)
    {
        return reports[_queryId].isDisputed[_timestamp];
    }

    /*
     * @dev Retrieve value from oracle based on timestamp
     * @param _queryId being requested
     * @param _timestamp to retrieve data/value from
     * @return bytes value for timestamp submitted
     */
    function retrieveData(bytes32 _queryId, uint256 _timestamp)
        public
        view
        returns (bytes memory)
    {
        return reports[_queryId].valueByTimestamp[_timestamp];
    }

    /*
     * @dev Used during the upgrade process to verify valid Tellor contracts
     * @return bool value used to verify valid Tellor contracts
     */
    function verify() external pure returns (uint256) {
        return 9999;
    }

    // *****************************************************************************
    // *                                                                           *
    // *                          Internal functions                               *
    // *                                                                           *
    // *****************************************************************************

    /*
     * @dev Retrieves latest array index of data before the specified timestamp for the queryId
     * @param _queryId is the queryId to look up the index for
     * @param _timestamp is the timestamp before which to search for the latest index
     * @return _found whether the index was found
     * @return _index the latest index found before the specified timestamp
     */
    function getIndexForDataBefore(bytes32 _queryId, uint256 _timestamp)
        public
        view
        returns (bool _found, uint256 _index)
    {
        uint256 _count = getNewValueCountbyQueryId(_queryId);
        if (_count > 0) {
            uint256 _middle;
            uint256 _start = 0;
            uint256 _end = _count - 1;
            uint256 _time;
            //Checking Boundaries to short-circuit the algorithm
            _time = getTimestampbyQueryIdandIndex(_queryId, _start);
            if (_time >= _timestamp) return (false, 0);
            _time = getTimestampbyQueryIdandIndex(_queryId, _end);
            if (_time < _timestamp) {
                while(isInDispute(_queryId, _time) && _end > 0) {
                    _end--;
                    _time = getTimestampbyQueryIdandIndex(_queryId, _end);
                }
                if(_end == 0 && isInDispute(_queryId, _time)) {
                    return (false, 0);
                }
                return (true, _end);
            }
            //Since the value is within our boundaries, do a binary search
            while (true) {
                _middle = (_end - _start) / 2 + 1 + _start;
                _time = getTimestampbyQueryIdandIndex(_queryId, _middle);
                if (_time < _timestamp) {
                    //get immediate next value
                    uint256 _nextTime = getTimestampbyQueryIdandIndex(
                        _queryId,
                        _middle + 1
                    );
                    if (_nextTime >= _timestamp) {
                        if(!isInDispute(_queryId, _time)) {
                            // _time is correct
                            return (true, _middle);
                        } else {
                            // iterate backwards until we find a non-disputed value
                            while(isInDispute(_queryId, _time) && _middle > 0) {
                                _middle--;
                                _time = getTimestampbyQueryIdandIndex(_queryId, _middle);
                            }
                            if(_middle == 0 && isInDispute(_queryId, _time)) {
                                return (false, 0);
                            }
                            // _time is correct
                            return (true, _middle);
                        }
                    } else {
                        //look from middle + 1(next value) to end
                        _start = _middle + 1;
                    }
                } else {
                    uint256 _prevTime = getTimestampbyQueryIdandIndex(
                        _queryId,
                        _middle - 1
                    );
                    if (_prevTime < _timestamp) {
                        if(!isInDispute(_queryId, _prevTime)) {
                            // _prevTime is correct
                            return (true, _middle - 1);
                        } else {
                            // iterate backwards until we find a non-disputed value
                            _middle--;
                            while(isInDispute(_queryId, _prevTime) && _middle > 0) {
                                _middle--;
                                _prevTime = getTimestampbyQueryIdandIndex(
                                    _queryId,
                                    _middle
                                );
                            }
                            if(_middle == 0 && isInDispute(_queryId, _prevTime)) {
                                return (false, 0);
                            }
                            // _prevtime is correct
                            return (true, _middle);
                        }
                    } else {
                        //look from start to middle -1(prev value)
                        _end = _middle - 1;
                    }
                }
            }
        }
        return (false, 0);
    }

    /*
     * @dev Returns the index of a reporter timestamp in the timestamp array for a specific data ID
     * @param _queryId is ID of the specific data feed
     * @param _timestamp is the timestamp to find in the timestamps array
     * @return uint256 of the index of the reporter timestamp in the array for specific ID
     */
    function getTimestampIndexByTimestamp(bytes32 _queryId, uint256 _timestamp)
        external
        view
        returns (uint256)
    {
        return reports[_queryId].timestampIndex[_timestamp];
    }

    /*
     * @dev Gets the timestamp for the value based on their index
     * @param _queryId is the id to look up
     * @param _index is the value index to look up
     * @return uint256 timestamp
     */
    function getTimestampbyQueryIdandIndex(bytes32 _queryId, uint256 _index)
        public
        view
        returns (uint256)
    {
        return reports[_queryId].timestamps[_index];
    }

    /**
     * @dev Called whenever a user's stake amount changes. First updates staking rewards,
     * transfers pending rewards to user's address, and finally updates user's stake amount
     * and other relevant variables.
     * @param _stakerAddress address of user whose stake is being updated
     * @param _newStakedBalance new staked balance of user
     */
    function _updateStakeAndPayRewards(
        address _stakerAddress,
        uint256 _newStakedBalance
    ) internal {
        StakeInfo storage _staker = stakerDetails[_stakerAddress];

        totalStakeAmount -= _staker.stakedBalance;
        _staker.stakedBalance = _newStakedBalance;
        // Update total stakers
        if (_staker.stakedBalance >= IFactory(factory).stakeAmount()) {
            if (_staker.staked == false) {
                totalStakers++;
            }
            _staker.staked = true;
        } else {
            if (_staker.staked == true && totalStakers > 0) {
                totalStakers--;
            }
            _staker.staked = false;
        }
        totalStakeAmount += _staker.stakedBalance;
    }

    /**
     * @dev Returns amount required to report oracle values
     * @return uint256 stake amount
     */
    function getStakeAmount() external view returns (uint256) {
        return IFactory(factory).stakeAmount();
    }

    /**
     * @dev Returns all information about a staker
     * @param _stakerAddress address of staker inquiring about
     * @return uint startDate of staking
     * @return uint current amount staked
     * @return uint current amount locked for withdrawal
     * @return uint reward debt used to calculate staking rewards
     * @return uint reporter's last reported timestamp
     * @return uint total number of reports submitted by reporter
     * @return uint governance vote count when first staked
     * @return uint number of votes cast by staker when first staked
     * @return bool whether staker is counted in totalStakers
     */
    function getStakerInfo(address _stakerAddress)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            bool
        )
    {
        StakeInfo storage _staker = stakerDetails[_stakerAddress];
        return (
            _staker.startDate,
            _staker.stakedBalance,
            _staker.lockedBalance,
            0,
            _staker.reporterLastTimestamp,
            _staker.reportsSubmitted,
            0,
            0,
            _staker.staked
        );
    }
}

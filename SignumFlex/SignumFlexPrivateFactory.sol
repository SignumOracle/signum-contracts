// SPDX-License-Identifier: MIT
pragma solidity 0.8.3;

import "./SignumFlexPrivate.sol";

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}

abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor() {
        _transferOwnership(_msgSender());
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

interface IGovernance {
    function addPrivateOracle(address _privateOracleAddress) external;
}

/*
 @author Tetra.win
 @title SignumFlexPrivateFactory
 @dev This is a streamlined Signum oracle system which handles reporting,
 * slashing, and user data getters in one contract. This contract is controlled
 * by a single address known as 'governance', which could be an externally owned
 * account or a contract, allowing for a flexible, modular design.
*/

contract SignumFlexPrivateFactory is Ownable {
    // Array to keep track of all deployed contracts
    address[] public deployedContracts;
    mapping(address => bool) public isPrivateOracle;

    // Fee parameters
    uint256 public creationFee = 0;
    address public feeReceiver = owner();
    address public feeToken = 0xefD766cCb38EaF1dfd701853BFCe31359239F305; // DAI

    // Reporter Requirement parameters
    uint256 public stakeAmount = 75000000000000000000000; // 75,000 SRB tokens
    uint256 public stakeLockTime = 365 days; // 1 year

    // Contracts
    IGovernance public governance = IGovernance(address(0x237a21b1bb4d0283c7590EA76e3Cc8B47985C9Ce));

    // Events
    event PrivateOracleDeployed(address indexed newContractAddress, address indexed deployer);
    event StakeRequirementsUpdated(uint256 newStakeAmount, uint256 newStakeLockTime);

    /**
     * @dev Deploys a new instance of the SignumFlexPrivate contract.
     * @return newContractAddress Address of the newly deployed contract.
     */
    function deploySignumFlexPrivate() external payable returns (address newContractAddress) {
        // Transfer creationFee
        if (creationFee > 0) {
        IERC20(feeToken).transferFrom(msg.sender, feeReceiver, creationFee);
        }

        // Deploy a new instance of the SignumFlexPrivate contract
        SignumFlexPrivate newContract = new SignumFlexPrivate(address(this));

        // Store the address of the new contract in the deployedContracts array
        deployedContracts.push(address(newContract));
        isPrivateOracle[address(newContract)] = true;
        //governance.addPrivateOracle(address(newContract));

        // Emit the ContractDeployed event
        emit PrivateOracleDeployed(address(newContract), msg.sender);

        // Return the address of the newly deployed contract
        return address(newContract);
    }

    /**
     * @dev Returns the number of contracts deployed by this factory.
     * @return uint256 The number of deployed contracts.
     */
    function getDeployedContractsCount() external view returns (uint256) {
        return deployedContracts.length;
    }

    /**
     * @dev Returns the address of the contract at a specific index in the deployedContracts array.
     * @param _index Index of the contract in the deployedContracts array.
     * @return address Address of the contract at the specified index.
     */
    function getDeployedContract(uint256 _index) external view returns (address) {
        require(_index < deployedContracts.length, "Index out of bounds");
        return deployedContracts[_index];
    }

    /**
     * @dev Allows the owner to update the creationFee and feeReceiver for private oracle deployments.
     * @param _creationFee Amount of PLS fee required to deploy a private oracle.
     * @param _feeReceiver Updates the wallet address receiver of creationFee.
     */
    function updateFeeSettings(uint256 _creationFee, address _feeReceiver) external onlyOwner {
        creationFee = _creationFee;
        feeReceiver = _feeReceiver;
    }

    /**
     * @dev Allows the owner to update the stakeAmount and stakeLockTime for private oracle deployments.
     * @param _stakeAmount Updates the amount of SRB stake required per reporter feeding private oracle.
     * @param _stakeLockTime Updates the amount of time (in seconds) that the reporter's stake is locked for.
     */
    function updateStakeRequirements(uint256 _stakeAmount, uint256 _stakeLockTime) external onlyOwner {
        stakeAmount = _stakeAmount;
        stakeLockTime = _stakeLockTime;
        emit StakeRequirementsUpdated(_stakeAmount, _stakeLockTime);
    }
}

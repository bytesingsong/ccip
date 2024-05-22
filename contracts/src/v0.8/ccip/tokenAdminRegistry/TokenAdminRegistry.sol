// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ITypeAndVersion} from "../../shared/interfaces/ITypeAndVersion.sol";
import {IPool} from "../interfaces/IPool.sol";
import {ITokenAdminRegistry} from "../interfaces/ITokenAdminRegistry.sol";

import {OwnerIsCreator} from "../../shared/access/OwnerIsCreator.sol";

import {EnumerableSet} from "../../vendor/openzeppelin-solidity/v4.8.3/contracts/utils/structs/EnumerableSet.sol";

/// @notice This contract stores the token pool configuration for all CCIP enabled tokens. It works
/// on a self-serve basis, where tokens can be registered without intervention from the CCIP owner.
/// @dev This contract is not considered upgradable, as it is a customer facing contract that will store
/// significant amounts of data.
contract TokenAdminRegistry is ITokenAdminRegistry, ITypeAndVersion, OwnerIsCreator {
  using EnumerableSet for EnumerableSet.AddressSet;

  error OnlyRegistryModule(address sender);
  error OnlyAdministrator(address sender, address token);
  error OnlyPendingAdministrator(address sender, address token);
  error AlreadyRegistered(address token);
  error ZeroAddress();

  event AdministratorRegistered(address indexed token, address indexed administrator);
  event PoolSet(address indexed token, address indexed previousPool, address indexed newPool);
  event AdministratorTransferRequested(address indexed token, address indexed currentAdmin, address indexed newAdmin);
  event AdministratorTransferred(address indexed token, address indexed newAdmin);
  event DisableReRegistrationSet(address indexed token, bool disabled);
  event RemovedAdministrator(address token);
  event RegistryModuleAdded(address module);
  event RegistryModuleRemoved(address indexed module);

  // The struct is packed in a way that optimizes the attributes that are accessed together.
  // solhint-disable-next-line gas-struct-packing
  struct TokenConfig {
    bool isRegistered; //  ─────────╮ if true, the token is registered in the registry
    bool disableReRegistration; //  │ if true, the token cannot be permissionlessly re-registered
    address administrator; // ──────╯ the current administrator of the token
    address pendingAdministrator; //  the address that is pending to become the new owner
    address tokenPool; // the token pool for this token. Can be address(0) if not deployed or not configured.
  }

  string public constant override typeAndVersion = "TokenAdminRegistry 1.5.0-dev";

  // Mapping of token address to token configuration
  mapping(address token => TokenConfig) internal s_tokenConfig;

  // All tokens that have been configured
  EnumerableSet.AddressSet internal s_tokens;

  // All permissioned tokens
  EnumerableSet.AddressSet internal s_permissionedTokens;

  // Registry modules are allowed to register administrators for tokens
  EnumerableSet.AddressSet internal s_RegistryModules;

  /// @notice Returns all pools for the given tokens.
  /// @dev Will return address(0) for tokens that do not have a pool.
  function getPools(address[] calldata tokens) external view returns (address[] memory) {
    address[] memory pools = new address[](tokens.length);
    for (uint256 i = 0; i < tokens.length; ++i) {
      pools[i] = s_tokenConfig[tokens[i]].tokenPool;
    }
    return pools;
  }

  /// @inheritdoc ITokenAdminRegistry
  function getPool(address token) external view returns (address) {
    return s_tokenConfig[token].tokenPool;
  }

  /// @notice Returns whether the given token can be sent to the given chain.
  /// @param token The token to check.
  /// @param remoteChainSelector The chain selector of the remote chain.
  /// @return True if the token can be sent to the given chain, false otherwise.
  /// @dev Due to the permissionless nature of the token pools, this function could return true even
  /// when any actual CCIP transaction containing this token to the given chain would fail. If the
  /// pool is properly written and configured, this function should be accurate.
  function isTokenSupportedOnRemoteChain(address token, uint64 remoteChainSelector) external view returns (bool) {
    address pool = s_tokenConfig[token].tokenPool;
    if (pool == address(0)) {
      return false;
    }
    return IPool(pool).isSupportedChain(remoteChainSelector);
  }

  /// @notice Returns the configuration for a token.
  /// @param token The token to get the configuration for.
  /// @return config The configuration for the token.
  function getTokenConfig(address token) external view returns (TokenConfig memory) {
    return s_tokenConfig[token];
  }

  /// @notice Returns a list of tokens that are configured in the token admin registry.
  /// @param startIndex Starting index in list, can be 0 if you want to start from the beginning.
  /// @param maxCount Maximum number of tokens to retrieve. Since the list can be large,
  /// it is recommended to use a paging mechanism to retrieve all tokens. If querying for very
  /// large lists, RPCs can time out. If you want all tokens, use type(uint64).max.
  /// @return tokens List of configured tokens.
  /// @dev The function is paginated to avoid RPC timeouts.
  /// @dev The ordering is guaranteed to remain the same as it is not possible to remove tokens
  /// from s_tokens.
  function getAllConfiguredTokens(uint64 startIndex, uint64 maxCount) external view returns (address[] memory tokens) {
    uint256 numberOfTokens = s_tokens.length();
    if (startIndex >= numberOfTokens) {
      return tokens;
    }
    uint256 count = maxCount;
    if (count + startIndex > numberOfTokens) {
      count = numberOfTokens - startIndex;
    }
    tokens = new address[](count);
    for (uint256 i = 0; i < count; ++i) {
      tokens[i] = s_tokens.at(startIndex + i);
    }

    return tokens;
  }

  // ================================================================
  // │                  Administrator functions                     │
  // ================================================================

  /// @notice Sets the pool for a token. Setting the pool to address(0) effectively delists the token
  /// from CCIP. Setting the pool to any other address enables the token on CCIP.
  /// @param localToken The token to set the pool for.
  /// @param pool The pool to set for the token.
  function setPool(address localToken, address pool) external onlyTokenAdmin(localToken) {
    TokenConfig storage config = s_tokenConfig[localToken];

    address previousPool = config.tokenPool;
    config.tokenPool = pool;

    if (previousPool != pool) {
      emit PoolSet(localToken, previousPool, pool);
    }
  }

  /// @notice Transfers the administrator role for a token to a new address with a 2-step process.
  /// @param localToken The token to transfer the administrator role for.
  /// @param newAdmin The address to transfer the administrator role to. Can be address(0) to cancel
  /// a pending transfer.
  /// @dev The new admin must call `acceptAdminRole` to accept the role.
  function transferAdminRole(address localToken, address newAdmin) external onlyTokenAdmin(localToken) {
    TokenConfig storage config = s_tokenConfig[localToken];
    config.pendingAdministrator = newAdmin;

    emit AdministratorTransferRequested(localToken, msg.sender, newAdmin);
  }

  /// @notice Accepts the administrator role for a token.
  /// @param localToken The token to accept the administrator role for.
  /// @dev This function can only be called by the pending administrator.
  function acceptAdminRole(address localToken) external {
    TokenConfig storage config = s_tokenConfig[localToken];
    if (config.pendingAdministrator != msg.sender) {
      revert OnlyPendingAdministrator(msg.sender, localToken);
    }

    config.administrator = msg.sender;
    config.pendingAdministrator = address(0);

    emit AdministratorTransferred(localToken, msg.sender);
  }

  /// @notice Disables the re-registration of a token.
  /// @param localToken The token to disable re-registration for.
  /// @param disabled True to disable re-registration, false to enable it.
  function setDisableReRegistration(address localToken, bool disabled) external onlyTokenAdmin(localToken) {
    s_tokenConfig[localToken].disableReRegistration = disabled;

    emit DisableReRegistrationSet(localToken, disabled);
  }

  // ================================================================
  // │                    Administrator config                      │
  // ================================================================

  /// @notice Public getter to check for permissions of an administrator
  function isAdministrator(address localToken, address administrator) public view returns (bool) {
    return s_tokenConfig[localToken].administrator == administrator;
  }

  /// @inheritdoc ITokenAdminRegistry
  /// @dev Can only be called by a registry module.
  function registerAdministrator(address localToken, address administrator) external {
    // Only allow permissioned registry modules to register administrators
    if (!isRegistryModule(msg.sender)) {
      revert OnlyRegistryModule(msg.sender);
    }
    TokenConfig storage config = s_tokenConfig[localToken];

    // disableReRegistration can only be true if the token is already registered
    if (config.disableReRegistration) {
      revert AlreadyRegistered(localToken);
    }

    _registerToken(config, localToken, administrator);
  }

  /// @notice Registers a local administrator for a token. This will overwrite any potential current administrator
  /// and set the permissionedAdmin to true.
  /// @param localToken The token to register the administrator for.
  /// @param administrator The address of the new administrator.
  /// @dev Can only be called by the owner.
  function registerAdministratorPermissioned(address localToken, address administrator) external onlyOwner {
    if (administrator == address(0)) {
      revert ZeroAddress();
    }
    TokenConfig storage config = s_tokenConfig[localToken];

    if (config.isRegistered) {
      revert AlreadyRegistered(localToken);
    }

    _registerToken(config, localToken, administrator);
  }

  function _registerToken(TokenConfig storage config, address localToken, address administrator) internal {
    config.administrator = administrator;
    config.isRegistered = true;

    s_tokens.add(localToken);

    emit AdministratorRegistered(localToken, administrator);
  }

  // ================================================================
  // │                      Registry Modules                        │
  // ================================================================

  /// @notice Checks if an address is a registry module.
  /// @param module The address to check.
  /// @return True if the address is a registry module, false otherwise.
  function isRegistryModule(address module) public view returns (bool) {
    return s_RegistryModules.contains(module);
  }

  /// @notice Adds a new registry module to the list of allowed modules.
  /// @param module The module to add.
  function addRegistryModule(address module) external onlyOwner {
    if (s_RegistryModules.add(module)) {
      emit RegistryModuleAdded(module);
    }
  }

  /// @notice Removes a registry module from the list of allowed modules.
  /// @param module The module to remove.
  function removeRegistryModule(address module) external onlyOwner {
    if (s_RegistryModules.remove(module)) {
      emit RegistryModuleRemoved(module);
    }
  }

  // ================================================================
  // │                           Access                             │
  // ================================================================

  /// @notice Checks if an address is the administrator of the given token.
  modifier onlyTokenAdmin(address token) {
    if (s_tokenConfig[token].administrator != msg.sender) {
      revert OnlyAdministrator(msg.sender, token);
    }
    _;
  }
}

/* Access Control page.
 *
 * Two panels: roles on the left, the selected role's ALLOW and DENY rules on the
 * right. Rules are staged locally and saved in one POST with an optimistic
 * version check.
 *
 * Note there is no <URL_PREFIX> placeholder in this file — it comes from
 * window.__URL_PREFIX__, set in the HTML. See js/admin-common.js for why.
 */
(function () {
    'use strict';

    var URL_PREFIX = (function () {
        var prefix = window.__URL_PREFIX__ || '/';
        if (prefix.charAt(0) !== '/') {
            prefix = '/' + prefix;
        }
        if (prefix.slice(-1) !== '/') {
            prefix += '/';
        }
        return prefix;
    })();

    var API_BASE = URL_PREFIX + 'fileserver/auth-config';

    // The operation vocabulary the server enforces, mirroring authorize.lua.
    // Allow has no "write" and deny has no "read".
    var OPERATIONS = {
        allow: ['read', 'all'],
        deny: ['all', 'write']
    };

    // Keycloak ships roles nobody grants storage access to. `admin` is
    // deliberately not here: it is a common name for a realm's own role, and
    // the master realm's built-in `admin` cannot be told from one by name.
    var NOISE_ROLES = {
        offline_access: true,
        uma_authorization: true,
        'create-realm': true
    };
    var NOISE_ROLE_PREFIXES = ['default-roles-'];

    var DEFAULT_ROLE = '.default';

    var state = {
        rules: {},            // role -> { allow: [], deny: [] } — staged, may be dirty
        version: null,
        savedJson: null,      // snapshot of the last server state
        roles: [],            // realm roles from Keycloak
        rolesSource: 'unavailable',
        rolesError: null,
        adminGroup: null,
        showAllRoles: false,
        selectedRole: null,
        search: '',
        editing: null         // { list: 'allow'|'deny', index: number|null }
    };

    var els = {};

    // ---------------------------------------------------------------- helpers

    function isDirty() {
        return JSON.stringify(state.rules) !== state.savedJson;
    }

    function isNoiseRole(name) {
        if (NOISE_ROLES[name]) {
            return true;
        }
        for (var i = 0; i < NOISE_ROLE_PREFIXES.length; i++) {
            if (name.indexOf(NOISE_ROLE_PREFIXES[i]) === 0) {
                return true;
            }
        }
        return false;
    }

    function configuredRoles() {
        return Object.keys(state.rules);
    }

    // The server requires BOTH lists on every role, even empty: validate_config
    // in lua/auth-config.lua rejects a role whose entry is {} or carries only one
    // of the two keys, with "Missing allow rules for group <role>". Nothing else
    // cares — renderRulesPanel falls back with `|| { allow: [], deny: [] }` and
    // validateBeforeSave with `|| []` — so a hand-written config, or one written
    // by a build older than that check, loads perfectly and then cannot be saved
    // from ANY role. The POST carries the whole config, so one role missing a
    // list blocks every save, and the error names a role the user never touched.
    // A config on the deployed instance is exactly this shape.
    function normaliseRuleSet(set) {
        if (!set || typeof set !== 'object') {
            set = {};
        }
        if (!Array.isArray(set.allow)) {
            set.allow = [];
        }
        if (!Array.isArray(set.deny)) {
            set.deny = [];
        }
        return set;
    }

    function normaliseRules(rules) {
        Object.keys(rules).forEach(function (role) {
            rules[role] = normaliseRuleSet(rules[role]);
        });
        return rules;
    }

    function showAlert(message) {
        els.notificationMessage.textContent = message;
        els.notificationAlert.classList.remove('d-none');
    }

    function clearAlert() {
        els.notificationAlert.classList.add('d-none');
    }

    function pluralise(count, singular, plural) {
        return count + ' ' + (count === 1 ? singular : (plural || singular + 's'));
    }

    // ---------------------------------------------------------------- loading

    function loadConfig() {
        return apiFetch(API_BASE).then(function (data) {
            // Normalise before the snapshot, so a config missing a list loads
            // clean rather than immediately looking dirty. See normaliseRuleSet.
            state.rules = normaliseRules(data.rules || {});
            state.version = data.version;
            state.savedJson = JSON.stringify(state.rules);
            if (!state.selectedRole) {
                state.selectedRole = pickInitialRole();
            }
            renderAll();
        });
    }

    function pickInitialRole() {
        var configured = configuredRoles().sort();
        if (configured.indexOf(DEFAULT_ROLE) !== -1) {
            return DEFAULT_ROLE;
        }
        if (configured.length > 0) {
            return configured[0];
        }
        return state.roles.length > 0 ? state.roles[0] : null;
    }

    function loadRoles(refresh) {
        var url = API_BASE + '/roles' + (refresh ? '?refresh=1' : '');
        return apiFetch(url).then(function (data) {
            state.roles = Array.isArray(data.roles) ? data.roles : [];
            state.rolesSource = data.source || 'unavailable';
            state.rolesError = data.error || null;
            state.adminGroup = data.admin_group || null;
            renderRoleList();
        }).catch(function (error) {
            // The editor stays usable with config-derived roles only.
            state.roles = [];
            state.rolesSource = 'unavailable';
            state.rolesError = error.message;
            renderRoleList();
        });
    }

    function start() {
        // Show the deployment's real prefix rather than a made-up example path.
        els.rulePath.placeholder = URL_PREFIX + 'download/';

        els.loadingIndicator.classList.remove('d-none');

        // Config first: the editor must not wait on Keycloak.
        loadConfig().then(function () {
            els.loadingIndicator.classList.add('d-none');
            els.contentSection.classList.remove('d-none');
        }).catch(function (error) {
            els.loadingIndicator.classList.add('d-none');
            showAlert('Could not load the configuration: ' + error.message);
        });

        loadRoles(false);
    }

    // ---------------------------------------------------------------- role list

    function renderRoleList() {
        var configured = configuredRoles();
        var known = {};
        state.roles.forEach(function (role) { known[role] = true; });

        var query = state.search.toLowerCase();
        var matches = function (role) {
            return !query || role.toLowerCase().indexOf(query) !== -1;
        };

        var pinned = configured.filter(function (role) { return role === DEFAULT_ROLE; });
        var rest = configured.filter(function (role) {
            return role !== DEFAULT_ROLE && matches(role);
        }).sort();

        var configuredHtml = pinned.map(renderRoleRow).concat(pinned.length ? [] : [])
            .concat(rest.map(renderRoleRow)).join('');

        // A configured role that Keycloak does not know about can never match at
        // runtime. Only meaningful when we actually reached Keycloak.
        els.roleListConfigured.innerHTML = configuredHtml;

        var other = state.roles.filter(function (role) {
            return !state.rules[role] && matches(role);
        }).filter(function (role) {
            return state.showAllRoles || !isNoiseRole(role);
        }).sort();

        els.roleListOther.innerHTML = other.length
            ? other.map(renderRoleRow).join('')
            : '<div class="role-empty">' +
              (state.rolesSource === 'unavailable' ? 'Role list unavailable' : 'No other roles') +
              '</div>';

        // Keycloak realms carry built-in roles nobody grants storage access to,
        // so they stay folded away until asked for.
        var hiddenNoise = state.roles.filter(function (role) {
            return !state.rules[role] && isNoiseRole(role) && matches(role);
        }).length;
        els.showAllRolesRow.classList.toggle('d-none', state.showAllRoles || hiddenNoise === 0);
        els.showAllRolesButton.textContent = 'Show ' + pluralise(hiddenNoise, 'more role');
        els.hideNoiseRolesButton.classList.toggle('d-none', !state.showAllRoles);

        els.rolesDegradedNotice.classList.toggle('d-none', state.rolesSource !== 'unavailable');
        if (state.rolesSource === 'unavailable') {
            els.rolesDegradedNotice.textContent = state.rolesError
                ? 'Roles from Keycloak are unavailable (' + state.rolesError + '). Showing roles already in the configuration.'
                : 'Roles from Keycloak are unavailable. Showing roles already in the configuration.';
        }

        var total = configured.length + other.length;
        els.roleCount.textContent = pluralise(total, 'role');
    }

    function renderRoleRow(role) {
        var rules = state.rules[role] || { allow: [], deny: [] };
        var isDefault = role === DEFAULT_ROLE;
        var isAdmin = state.adminGroup && role === state.adminGroup;
        var isKnown = state.roles.indexOf(role) !== -1;
        var stale = state.rolesSource !== 'unavailable' && state.roles.length > 0 && !isKnown && !isDefault;

        var badges = [];
        var allowCount = (rules.allow || []).length;
        var denyCount = (rules.deny || []).length;
        if (allowCount) {
            badges.push('<span class="count allow" title="' + allowCount + ' allow rules">' + allowCount + '</span>');
        }
        if (denyCount) {
            badges.push('<span class="count deny" title="' + denyCount + ' deny rules">' + denyCount + '</span>');
        }

        var icons = '';
        if (isDefault) {
            icons += '<span class="role-icon pin" title="Fallback role — cannot be deleted">' +
                '<i class="ti ti-pin"></i></span>';
        }
        if (isAdmin) {
            icons += '<span class="role-icon admin" title="Admin role — deleting its rules can lock you out">' +
                '<i class="ti ti-shield"></i></span>';
        }

        return '<div class="role-row' + (role === state.selectedRole ? ' active' : '') + '"' +
            ' data-role="' + escapeAttr(role) + '" role="button" tabindex="0">' +
            icons +
            '<span class="role-name">' + escapeHtml(role) + '</span>' +
            (stale ? '<span class="role-stale" title="This role is not present in Keycloak">not in Keycloak</span>' : '') +
            '<span class="counts">' + badges.join('') + '</span>' +
            '</div>';
    }

    function selectRole(role) {
        state.selectedRole = role;
        renderRoleList();
        renderRulesPanel();
    }

    // ---------------------------------------------------------------- rules

    function renderRulesPanel() {
        var role = state.selectedRole;
        if (!role) {
            els.rulesCard.classList.add('d-none');
            els.rulesPlaceholder.classList.remove('d-none');
            return;
        }

        els.rulesPlaceholder.classList.add('d-none');
        els.rulesCard.classList.remove('d-none');

        var rules = state.rules[role] || { allow: [], deny: [] };
        els.rulesTitle.textContent = role;
        els.rulesTitle.className = 'role-title' + (role === state.adminGroup ? ' admin' : '');

        var isDefault = role === DEFAULT_ROLE;
        els.deleteRoleButton.classList.toggle('d-none', isDefault);

        var isAdmin = state.adminGroup && role === state.adminGroup;
        els.adminWarning.classList.toggle('d-none', !isAdmin);
        els.adminWarningText.textContent = 'This is the admin role. Removing its rules can lock you out of ' +
            'this page — it is what grants access to it.';

        // A .default with no rules denies everyone whose roles matched nothing.
        var emptyDefault = isDefault && (rules.allow || []).length === 0;
        els.defaultWarning.classList.toggle('d-none', !emptyDefault);

        renderRuleTable('allow', rules.allow || []);
        renderRuleTable('deny', rules.deny || []);

        els.allowCount.textContent = pluralise((rules.allow || []).length, 'rule');
        els.denyCount.textContent = pluralise((rules.deny || []).length, 'rule');
    }

    function renderRuleTable(listName, rules) {
        var table = listName === 'allow' ? els.allowTable : els.denyTable;
        var empty = listName === 'allow' ? els.allowEmpty : els.denyEmpty;

        if (rules.length === 0) {
            table.innerHTML = '';
            table.classList.add('d-none');
            empty.classList.remove('d-none');
            empty.textContent = listName === 'allow'
                ? 'No allow rules — this role can reach nothing unless a broader rule covers it.'
                : 'No deny rules — this role is never explicitly blocked.';
            return;
        }

        empty.classList.add('d-none');
        table.classList.remove('d-none');

        var known = OPERATIONS[listName];
        var rows = rules.map(function (rule, index) {
            var parts = splitRule(rule);
            var invalid = known.indexOf(parts.operation) === -1;

            return '<tr class="rule-row" data-list="' + listName + '" data-index="' + index + '">' +
                '<td class="rule-op-cell"><span class="op ' + escapeAttr(parts.operation) + '">' +
                escapeHtml(parts.operation.toUpperCase()) + '</span>' +
                (invalid ? '<span class="chip invalid" title="This operation is not one the server implements, ' +
                    'so the rule never matches. Edit it to pick a valid one.">invalid</span>' : '') +
                '</td>' +
                '<td class="rule-path" title="' + escapeAttr(parts.path) + '">' + escapeHtml(parts.path) + '</td>' +
                '<td class="rule-actions">' +
                '<button type="button" class="icon-btn" data-action="edit" title="Edit rule" ' +
                'aria-label="Edit rule"><i class="ti ti-pencil"></i></button>' +
                '<button type="button" class="icon-btn danger" data-action="remove" title="Remove rule" ' +
                'aria-label="Remove rule"><i class="ti ti-trash"></i></button>' +
                '</td>' +
                '</tr>';
        }).join('');

        table.innerHTML = '<thead><tr>' +
            '<th class="col-op">Operation</th><th>Path prefix</th><th class="col-actions"></th>' +
            '</tr></thead><tbody>' + rows + '</tbody>';
    }

    function splitRule(rule) {
        var separator = rule.indexOf(':');
        if (separator === -1) {
            return { operation: 'all', path: rule };
        }
        return { operation: rule.slice(0, separator), path: rule.slice(separator + 1) };
    }

    // ---------------------------------------------------------------- dirty state

    function renderDirtyState() {
        var dirty = isDirty();
        els.saveButton.disabled = !dirty;
        // A class on the button, not a child element: setBusy/clearBusy replace
        // the button's innerHTML, so anything inside it is rebuilt on every save
        // and a cached reference to it goes stale. The dot itself is a ::after
        // in the page's CSS. See the .save-dirty rule for the full story.
        els.saveButton.classList.toggle('save-dirty', dirty);
    }

    function renderAll() {
        renderRoleList();
        renderRulesPanel();
        renderDirtyState();
    }

    // ---------------------------------------------------------------- rule modal

    // ---------------------------------------------------------------- tree picker

    var picker = { expanded: {}, selected: null };

    function pickerNodeId(path) {
        return 'picker-node-' + safeBtoa(path);
    }

    function pickerChildrenId(path) {
        return 'picker-children-' + safeBtoa(path);
    }

    function pickerNodeHtml(path, name, hasChildren, depth) {
        return '<div class="tree-node" id="' + pickerNodeId(path) + '"' +
            ' role="treeitem" tabindex="-1" aria-level="' + depth + '" aria-selected="false"' +
            (hasChildren ? ' aria-expanded="false"' : '') +
            ' data-path="' + escapeAttr(path) + '"' +
            ' data-has-children="' + (hasChildren ? '1' : '0') + '"' +
            ' data-depth="' + depth + '">' +
            '<span class="tree-toggle" data-toggle="1" aria-hidden="true">' +
            (hasChildren ? '<i class="ti ti-chevron-right"></i>' : '') +
            '</span>' +
            '<i class="ti ti-folder tree-folder"></i>' +
            '<span class="tree-name">' + escapeHtml(name) + '</span>' +
            '</div>' +
            '<div class="tree-children" id="' + pickerChildrenId(path) + '" role="group"></div>';
    }

    // The three bucket roots are rendered without a request; everything below
    // them loads on expand.
    function resetPicker() {
        picker = { expanded: {}, selected: null };

        var roots = ['download', 'public', 'archive'].map(function (bucket) {
            return pickerNodeHtml(URL_PREFIX + bucket, bucket, true, 1);
        }).join('');

        els.rulePickerArea.innerHTML =
            '<label class="field-label" id="pickerLabel">Browse</label>' +
            '<div class="picker-box">' +
            '<div class="picker-head">Choose a folder to fill the path</div>' +
            '<div class="tree" id="pickerTree" role="tree" aria-labelledby="pickerLabel">' +
            roots +
            '</div></div>';

        var first = els.rulePickerArea.querySelector('.tree-node');
        if (first) {
            first.setAttribute('tabindex', '0');
        }
    }

    function setToggleIcon(node, expanded, loading) {
        var toggle = node.querySelector('.tree-toggle');
        if (!toggle) {
            return;
        }
        if (loading) {
            toggle.innerHTML = '<span class="spinner-border spinner-border-sm"></span>';
            return;
        }
        toggle.innerHTML = '<i class="ti ti-chevron-' + (expanded ? 'down' : 'right') + '"></i>';
    }

    function togglePickerNode(path) {
        var node = document.getElementById(pickerNodeId(path));
        var children = document.getElementById(pickerChildrenId(path));
        if (!node || !children) {
            return Promise.resolve();
        }

        if (picker.expanded[path]) {
            children.innerHTML = '';
            picker.expanded[path] = false;
            node.setAttribute('aria-expanded', 'false');
            setToggleIcon(node, false);
            return Promise.resolve();
        }

        picker.expanded[path] = true;
        node.setAttribute('aria-expanded', 'true');
        setToggleIcon(node, true, true);

        var depth = parseInt(node.dataset.depth, 10) + 1;

        return apiFetch(API_BASE + '/dirs?path=' + encodeURIComponent(path)).then(function (data) {
            var entries = Array.isArray(data) ? data : [];
            setToggleIcon(node, true);

            if (entries.length === 0) {
                children.innerHTML = '<div class="tree-empty">No subfolders</div>';
                return;
            }
            children.innerHTML = entries.map(function (entry) {
                return pickerNodeHtml(entry.path, entry.name, entry.has_children, depth);
            }).join('');
        }).catch(function (error) {
            picker.expanded[path] = false;
            node.setAttribute('aria-expanded', 'false');
            setToggleIcon(node, false);
            children.innerHTML = '<div class="tree-empty text-danger">' + escapeHtml(error.message) + '</div>';
        });
    }

    function selectPickerNode(path) {
        var previous = els.rulePickerArea.querySelector('.tree-node.active');
        if (previous) {
            previous.classList.remove('active');
            previous.setAttribute('aria-selected', 'false');
        }

        var node = document.getElementById(pickerNodeId(path));
        if (node) {
            node.classList.add('active');
            node.setAttribute('aria-selected', 'true');
        }

        picker.selected = path;
        els.rulePath.value = path;
        els.rulePathError.classList.add('d-none');
    }

    // Walk down to a path so an existing rule's folder is visible in the tree.
    // Each level has to render before the next container exists, so the expands
    // are chained.
    function revealPickerPath(path) {
        if (path.indexOf(URL_PREFIX) !== 0) {
            return;
        }

        var segments = path.slice(URL_PREFIX.length).split('/').filter(Boolean);
        if (segments.length === 0) {
            return;
        }

        var base = URL_PREFIX.replace(/\/$/, '');
        var chain = segments.map(function (segment) {
            base += '/' + segment;
            return base;
        });

        var steps = Promise.resolve();
        chain.slice(0, -1).forEach(function (ancestor) {
            steps = steps.then(function () {
                if (picker.expanded[ancestor]) {
                    return undefined;
                }
                return togglePickerNode(ancestor);
            });
        });

        steps.then(function () {
            selectPickerNode(path);
        });
    }

    function visiblePickerNodes() {
        var nodes = els.rulePickerArea.querySelectorAll('.tree-node');
        return Array.prototype.filter.call(nodes, function (node) {
            return node.offsetParent !== null;
        });
    }

    function focusPickerNode(node) {
        var nodes = els.rulePickerArea.querySelectorAll('.tree-node');
        Array.prototype.forEach.call(nodes, function (item) {
            item.setAttribute('tabindex', '-1');
        });
        node.setAttribute('tabindex', '0');
        node.focus();
    }

    function pickerKeydown(event) {
        var node = event.target.closest('.tree-node');
        if (!node) {
            return;
        }
        var path = node.dataset.path;
        var nodes = visiblePickerNodes();
        var index = nodes.indexOf(node);

        switch (event.key) {
        case 'ArrowDown':
            event.preventDefault();
            if (index < nodes.length - 1) {
                focusPickerNode(nodes[index + 1]);
            }
            break;
        case 'ArrowUp':
            event.preventDefault();
            if (index > 0) {
                focusPickerNode(nodes[index - 1]);
            }
            break;
        case 'ArrowRight':
            event.preventDefault();
            if (!picker.expanded[path] && node.dataset.hasChildren === '1') {
                togglePickerNode(path);
            } else if (index < nodes.length - 1) {
                focusPickerNode(nodes[index + 1]);
            }
            break;
        case 'ArrowLeft':
            event.preventDefault();
            if (picker.expanded[path]) {
                togglePickerNode(path);
            } else {
                var parent = node.parentElement.previousElementSibling;
                if (parent && parent.classList.contains('tree-node')) {
                    focusPickerNode(parent);
                }
            }
            break;
        case 'Enter':
        case ' ':
            event.preventDefault();
            selectPickerNode(path);
            break;
        default:
            break;
        }
    }

    function openRuleModal(listName, index) {
        openers.ruleModal = document.activeElement;
        state.editing = { list: listName, index: index === undefined ? null : index };

        var role = state.selectedRole;
        var isEdit = state.editing.index !== null;
        var existing = isEdit ? state.rules[role][listName][state.editing.index] : null;

        els.ruleModalTitle.textContent = (isEdit ? 'Edit ' : 'Add ') + listName + ' rule — ' + role;
        els.rulePathError.classList.add('d-none');

        els.ruleOp.innerHTML = OPERATIONS[listName].map(function (operation) {
            return '<option value="' + escapeAttr(operation) + '">' + escapeHtml(operation) + '</option>';
        }).join('');

        var existingPath = null;
        if (existing) {
            var parts = splitRule(existing);
            existingPath = parts.path;
            els.ruleOp.value = OPERATIONS[listName].indexOf(parts.operation) === -1
                ? OPERATIONS[listName][0]
                : parts.operation;
            els.rulePath.value = parts.path;
        } else {
            els.rulePath.value = '';
        }

        resetPicker();
        ruleModal.show();

        if (existingPath) {
            revealPickerPath(existingPath);
        }
    }

    function rulePathError(message) {
        els.rulePathError.textContent = message;
        els.rulePathError.classList.remove('d-none');
    }

    // Where a staged rule is written. A role picked from "Other roles" has no
    // entry at all until it is given one, and the reads tolerate that
    // (renderRulesPanel falls back, validateBeforeSave uses `|| []`) while the
    // writes did not — clicking Add rule on such a role threw inside the click
    // handler, so nothing visibly happened: no dialog error, no staged row, no
    // toast. Give it the same shape the server demands, creating the entry only
    // when a rule is actually being written into it so merely opening the dialog
    // never marks the page dirty.
    function ruleListFor(role, listName) {
        state.rules[role] = normaliseRuleSet(state.rules[role]);
        return state.rules[role][listName];
    }

    function submitRule() {
        var role = state.selectedRole;
        var listName = state.editing.list;
        var index = state.editing.index;
        var operation = els.ruleOp.value;
        var path = els.rulePath.value.trim();

        if (!path) {
            rulePathError('Enter a path.');
            return;
        }
        if (path.charAt(0) !== '/') {
            rulePathError("The path must start with '/'.");
            return;
        }
        if (path === '/') {
            rulePathError('A root rule would match every URL. Choose a folder instead.');
            return;
        }
        if (path.indexOf('..') !== -1) {
            rulePathError("The path cannot contain '..'.");
            return;
        }
        if (URL_PREFIX !== '/' && path.indexOf(URL_PREFIX) !== 0) {
            rulePathError('Paths must start with ' + URL_PREFIX + ' to match a request.');
            return;
        }

        var rule = operation + ':' + path;
        var rules = ruleListFor(role, listName);

        var duplicate = rules.some(function (existing, position) {
            return existing === rule && position !== index;
        });
        if (duplicate) {
            rulePathError('That rule already exists for this role.');
            return;
        }

        if (index === null) {
            rules.push(rule);
        } else {
            rules[index] = rule;
        }

        ruleModal.hide();
        renderAll();
    }

    function removeRule(listName, index) {
        var role = state.selectedRole;
        var set = state.rules[role];
        var rules = set && set[listName];

        // Nothing rendered can be removed — a role with no entry, or a list that
        // was never there. Read-only on purpose: removing must not create one.
        if (!rules || index < 0 || index >= rules.length) {
            return;
        }

        var rule = rules[index];
        if (!window.confirm('Remove the rule "' + rule + '" from ' + role + '?')) {
            return;
        }
        rules.splice(index, 1);
        renderAll();
    }

    // ---------------------------------------------------------------- role CRUD

    function addRole() {
        var name = els.newRoleName.value.trim();

        if (!name) {
            els.newRoleError.textContent = 'Enter a role name.';
            els.newRoleError.classList.remove('d-none');
            return;
        }
        // authorize.lua splits X-USER-GROUPS on commas and strips all whitespace,
        // so a name with a space can never match and a comma would corrupt it.
        if (!/^[A-Za-z0-9._-]+$/.test(name)) {
            els.newRoleError.textContent = 'Use only letters, digits, dot, underscore and hyphen.';
            els.newRoleError.classList.remove('d-none');
            return;
        }
        if (state.rules[name]) {
            els.newRoleError.textContent = 'That role already has rules.';
            els.newRoleError.classList.remove('d-none');
            return;
        }

        state.rules[name] = { allow: [], deny: [] };
        addRoleModal.hide();
        selectRole(name);
        renderDirtyState();
    }

    function deleteRole() {
        var role = state.selectedRole;
        if (role === DEFAULT_ROLE) {
            return;
        }
        if (!window.confirm('Delete all rules for ' + role + '?')) {
            return;
        }
        delete state.rules[role];
        state.selectedRole = pickInitialRole();
        renderAll();
    }

    // ---------------------------------------------------------------- save

    // Mirrors the server's rules. The POST body is the whole config, so one
    // invalid rule would block every save until it is found — catch it here and
    // point at the row instead.
    function validateBeforeSave(rules) {
        var lists = ['allow', 'deny'];

        for (var role in rules) {
            if (!Object.prototype.hasOwnProperty.call(rules, role)) {
                continue;
            }
            var ruleSet = rules[role] || {};

            for (var l = 0; l < lists.length; l++) {
                var listName = lists[l];
                var list = ruleSet[listName] || [];

                for (var i = 0; i < list.length; i++) {
                    var operation = splitRule(list[i]).operation;
                    if (OPERATIONS[listName].indexOf(operation) === -1) {
                        return 'Role "' + role + '" has an ' + listName + ' rule with the unsupported ' +
                            'operation "' + operation + '" (' + list[i] + '). The server rejects it — ' +
                            'edit that rule to pick a valid operation.';
                    }
                }
            }
        }

        return null;
    }

    function saveConfig() {
        if (!isDirty()) {
            return;
        }

        var problem = validateBeforeSave(state.rules);
        if (problem) {
            showAlert(problem);
            if (state.selectedRole) {
                selectRole(state.selectedRole);
            }
            return;
        }

        clearAlert();
        setBusy(els.saveButton, '<span class="spinner-border spinner-border-sm"></span> Saving');

        apiFetch(API_BASE, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ version: state.version, rules: state.rules })
        }).then(function (data) {
            state.rules = normaliseRules(data.rules || {});
            state.version = data.version;
            state.savedJson = JSON.stringify(state.rules);
            if (!state.rules[state.selectedRole]) {
                state.selectedRole = pickInitialRole();
            }
            clearBusy(els.saveButton);
            renderAll();
            if (window.showToast) {
                window.showToast('Configuration saved.', 'success');
            }
        }).catch(function (error) {
            clearBusy(els.saveButton);

            if (error.status === 409) {
                // Deliberately no automatic reload — that would discard the
                // unsaved edits this admin is looking at.
                conflictModal.show();
                return;
            }
            if (error.status === 403) {
                showAlert(error.message);
                return;
            }
            showAlert('Could not save: ' + error.message);
        });
    }

    // ---------------------------------------------------------------- export / refresh

    function exportConfig() {
        var blob = new Blob([JSON.stringify({ version: state.version, rules: state.rules }, null, 2)], {
            type: 'application/json'
        });
        var url = URL.createObjectURL(blob);
        var link = document.createElement('a');
        link.href = url;
        link.download = 'auth_config_' + new Date().toISOString().slice(0, 10) + '.json';
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        URL.revokeObjectURL(url);
    }

    function refresh() {
        if (isDirty() && !window.confirm('Discard unsaved changes and reload?')) {
            return;
        }
        clearAlert();
        els.loadingIndicator.classList.remove('d-none');
        Promise.all([loadConfig(), loadRoles(true)]).then(function () {
            els.loadingIndicator.classList.add('d-none');
            if (window.showToast) {
                window.showToast('Reloaded.', 'success');
            }
        }).catch(function (error) {
            els.loadingIndicator.classList.add('d-none');
            showAlert('Could not reload: ' + error.message);
        });
    }

    // ---------------------------------------------------------------- wiring

    var ruleModal;
    var addRoleModal;
    var conflictModal;

    // Which element opened each modal, so focus can go back there on close.
    var openers = { ruleModal: null, addRoleModal: null };

    // Bootstrap ignores Modal.hide() while a dialog is still opening (it returns
    // early on its own _isTransitioning). A Save clicked inside that window — the
    // backdrop alone takes ~170ms — therefore leaves the dialog open for good:
    // the rule is staged, nothing visibly happens, and clicking Save again
    // reports it as a duplicate. Remember the close and apply it once Bootstrap
    // says the dialog is up.
    function readyModal(id) {
        var element = document.getElementById(id);
        var instance = new bootstrap.Modal(element);
        var shown = false;
        var pendingClose = false;

        element.addEventListener('shown.bs.modal', function () {
            shown = true;
            if (pendingClose) {
                pendingClose = false;
                instance.hide();
            }
        });
        element.addEventListener('hidden.bs.modal', function () {
            shown = false;
            pendingClose = false;
        });

        return {
            show: function () {
                instance.show();
            },
            hide: function () {
                if (shown) {
                    instance.hide();
                } else {
                    pendingClose = true;
                }
            }
        };
    }

    function cacheElements() {
        var ids = [
            'notificationAlert', 'notificationMessage', 'loadingIndicator', 'contentSection',
            'roleSearch', 'roleListConfigured', 'roleListOther', 'roleCount', 'rolesDegradedNotice',
            'showAllRolesRow', 'showAllRolesButton', 'hideNoiseRolesButton',
            'addRoleButton', 'rulesPlaceholder', 'rulesCard', 'rulesTitle', 'deleteRoleButton',
            'adminWarning', 'adminWarningText', 'defaultWarning',
            'allowTable', 'allowEmpty', 'allowCount', 'addAllowRuleButton',
            'denyTable', 'denyEmpty', 'denyCount', 'addDenyRuleButton',
            'refreshButton', 'exportButton', 'saveButton',
            'ruleModalTitle', 'ruleOp', 'rulePath', 'rulePathError', 'ruleSaveButton', 'rulePickerArea',
            'newRoleName', 'newRoleError', 'addRoleConfirmButton',
            'conflictReloadButton'
        ];
        ids.forEach(function (id) {
            els[id] = document.getElementById(id);
        });
    }

    function wireEvents() {
        els.roleSearch.addEventListener('input', function (event) {
            state.search = event.target.value;
            renderRoleList();
        });

        function roleListClick(event) {
            var row = event.target.closest('.role-row');
            if (row) {
                selectRole(row.dataset.role);
            }
        }
        els.roleListConfigured.addEventListener('click', roleListClick);
        els.roleListOther.addEventListener('click', roleListClick);

        els.roleListConfigured.addEventListener('keydown', roleListKeydown);
        els.roleListOther.addEventListener('keydown', roleListKeydown);

        els.showAllRolesButton.addEventListener('click', function () {
            state.showAllRoles = true;
            renderRoleList();
        });
        els.hideNoiseRolesButton.addEventListener('click', function () {
            state.showAllRoles = false;
            renderRoleList();
        });

        // Delegated, so rule rows carry only data attributes: no inline handler
        // and no need to escape a path into a string literal.
        function tableClick(event) {
            var button = event.target.closest('button[data-action]');
            if (!button) {
                return;
            }
            var row = button.closest('.rule-row');
            var listName = row.dataset.list;
            var index = parseInt(row.dataset.index, 10);

            if (button.dataset.action === 'edit') {
                openRuleModal(listName, index, button);
            } else if (button.dataset.action === 'remove') {
                removeRule(listName, index);
            }
        }
        els.allowTable.addEventListener('click', tableClick);
        els.denyTable.addEventListener('click', tableClick);

        // One delegated listener for the whole tree. Clicking a folder fills the
        // path; the chevron (and a double click) expand it.
        els.rulePickerArea.addEventListener('click', function (event) {
            var node = event.target.closest('.tree-node');
            if (!node) {
                return;
            }
            if (event.target.closest('[data-toggle]')) {
                togglePickerNode(node.dataset.path);
                return;
            }
            selectPickerNode(node.dataset.path);
            focusPickerNode(node);
        });

        els.rulePickerArea.addEventListener('dblclick', function (event) {
            var node = event.target.closest('.tree-node');
            if (node && node.dataset.hasChildren === '1') {
                togglePickerNode(node.dataset.path);
            }
        });

        els.rulePickerArea.addEventListener('keydown', pickerKeydown);

        els.addAllowRuleButton.addEventListener('click', function () { openRuleModal('allow'); });
        els.addDenyRuleButton.addEventListener('click', function () { openRuleModal('deny'); });
        els.ruleSaveButton.addEventListener('click', submitRule);
        els.deleteRoleButton.addEventListener('click', deleteRole);
        els.addRoleButton.addEventListener('click', function () {
            openers.addRoleModal = document.activeElement;
            els.newRoleName.value = '';
            els.newRoleError.classList.add('d-none');
            addRoleModal.show();
        });
        els.addRoleConfirmButton.addEventListener('click', addRole);
        els.saveButton.addEventListener('click', saveConfig);
        els.exportButton.addEventListener('click', exportConfig);
        els.refreshButton.addEventListener('click', refresh);
        els.conflictReloadButton.addEventListener('click', function () {
            window.location.reload();
        });

        // Bootstrap marks a hiding modal aria-hidden before it moves focus out,
        // and the browser blocks that while a descendant still has focus. `hide`
        // is dispatched first, so clearing focus here covers every dismissal path
        // — Save, Cancel, the close button and the backdrop alike. The modals
        // opt out of Bootstrap's focus trap (data-bs-focus="false") because it
        // otherwise pulls focus straight back in and the hide never settles.
        [['ruleModal', 'rulePath'], ['addRoleModal', 'newRoleName']].forEach(function (pair) {
            var modalElement = document.getElementById(pair[0]);
            var firstField = document.getElementById(pair[1]);

            modalElement.addEventListener('shown.bs.modal', function () {
                firstField.focus();
            });
            modalElement.addEventListener('hide.bs.modal', function () {
                if (modalElement.contains(document.activeElement)) {
                    document.activeElement.blur();
                }
                var opener = openers[pair[0]];
                if (opener && document.contains(opener)) {
                    opener.focus();
                }
            });
        });

        window.addEventListener('beforeunload', function (event) {
            if (isDirty()) {
                event.preventDefault();
                event.returnValue = '';
            }
        });
    }

    function roleListKeydown(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            var row = event.target.closest('.role-row');
            if (row) {
                event.preventDefault();
                selectRole(row.dataset.role);
            }
        }
    }

    document.addEventListener('DOMContentLoaded', function () {
        cacheElements();
        ruleModal = readyModal('ruleModal');
        addRoleModal = readyModal('addRoleModal');
        conflictModal = readyModal('conflictModal');
        wireEvents();
        start();
    });
})();

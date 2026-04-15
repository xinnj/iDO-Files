import {modifyContent} from './actions.js';

const addEvent = (function () {
    if (document.addEventListener) {
        return function (el, type, fn) {
            if (el && el.nodeName || el === window) {
                el.addEventListener(type, fn, false);
            } else if (el && el.length) {
                for (let i = 0; i < el.length; i++) {
                    addEvent(el[i], type, fn);
                }
            }
        };
    } else {
        return function (el, type, fn) {
            if (el && el.nodeName || el === window) {
                el.attachEvent('on' + type, function () {
                    return fn.call(el, window.event);
                });
            } else if (el && el.length) {
                for (let i = 0; i < el.length; i++) {
                    addEvent(el[i], type, fn);
                }
            }
        };
    }
})();

if (!!(window.history && history.pushState)) {
    addEvent(window, 'popstate', function (e) {
        if (!swapPage(window.location.pathname)) {
            history.go(-1);
        } else {
            updateCrumbs();
        }
    });

    initHistory();
}

export function updateCrumbs() {
    window.document.title = decodeURIComponent(window.location.pathname);
    setTimeout(function () {
        let loc = window.location.pathname;
        let currentPath = '<URL_PREFIX>';
        if (loc.startsWith(currentPath)) {
            loc = loc.slice(currentPath.length);
        }
        const segments = loc.split('/');
        let breadcrumbs = '';

        const currentRoot = segments[0] || 'download';

        const rootOptions = ['archive', 'download', 'public'];
        let dropdownItems = '';
        rootOptions.forEach(option => {
            if (option !== currentRoot) {
                dropdownItems += `<a href="${currentPath}${option}/">${option}</a>`;
            }
        });

        breadcrumbs += `
            <div class="dropdown">
                <a class="dropdown-toggle" href="${currentPath}${currentRoot}/">
                    ${currentRoot}
                    <span class="dropdown-arrow">▼</span>
                </a>
                <div class="dropdown-menu">
                    ${dropdownItems}
                </div>
            </div>`;
        currentPath += currentRoot + '/';

        for (let i = 1; i < segments.length; i++) {
            if (segments[i] !== '') {
                if (i == segments.length - 1) {
                    currentPath += segments[i];
                } else {
                    currentPath += segments[i] + '/';
                }
                breadcrumbs += '<a href="' + currentPath + '">' + decodeURIComponent(segments[i]) + '<\/a>';
            }
        }
        document.getElementById('breadcrumbs').innerHTML = breadcrumbs;
    }, 500);

    initSort();
    modifyContent(window.location.pathname);
};

function swapPage(href) {
    let req = false;
    if (window.XMLHttpRequest) {
        req = new XMLHttpRequest();
    } else if (window.ActiveXObject) {
        req = new ActiveXObject('Microsoft.XMLHTTP');
    }
    req.open('GET', href, false);
    req.send(null);
    if (req.status == 200) {
        const target = document.getElementsByClassName('box-content')[0];
        const div = document.createElement('div');
        div.innerHTML = req.responseText;
        const elements = div.getElementsByClassName('box-content')[0];
        target.innerHTML = elements.innerHTML;
        initHistory();
        return true;
        // Terrible error catching implemented! Basically, if the ajax request fails
        // we'll just refresh the entire page with the new URL.
    } else if (req.status === 403) {
        showError('Access Denied');
        return false;
    } else {
        window.location.replace(href);
        return false;
    }
};

function initHistory() {
    const list = document.getElementById('list');

    addEvent(list, 'click', function (event) {
        if (event.target.nodeName == 'A' && event.target.innerHTML.indexOf('/') !== -1) {
            event.preventDefault();

            const previousURL = window.location.href;

            if (swapPage(event.target.href)) {
                const title = event.target.innerHTML;
                history.pushState({page: title}, title, event.target.href);
                updateCrumbs();
            } else {
                history.replaceState(null, document.title, previousURL);
            }
        }
    });
};

function initSort() {
    // 解析URL参数
    const params = new URLSearchParams(window.location.search);
    const sortCol = params.get('C') || 'M';
    const sortOrder = params.get('O') || 'D';

    // 获取表头元素
    const headers = document.querySelectorAll('#list thead th');

    // 为每个表头添加排序指示器
    headers.forEach((header, index) => {
        const links = header.querySelectorAll('a');

        if (links.length > 0) {
            // 保留第一个链接的文本内容
            const headerText = document.createElement('span');
            headerText.className = 'header-text';
            headerText.textContent = links[0].textContent.trim();

            // 清空th内容
            header.innerHTML = '';

            // 添加文本和指示器
            header.appendChild(headerText);
        }

        // 创建排序指示器元素
        const indicator = document.createElement('span');
        indicator.className = 'sort-indicator';

        // 添加到表头
        header.appendChild(indicator);

        // 移除所有活动状态
        header.classList.remove('active-sort');
        const indicatorSort = header.querySelector('.sort-indicator');
        if (indicatorSort) {
            indicatorSort.textContent = '';
        }

        // 添加点击事件处理
        header.addEventListener('click', function () {
            const sortMap = {0: 'N', 1: 'S', 2: 'M'};
            const currentSort = sortMap[index];

            let newOrder = 'D';

            // 如果是当前排序列，切换排序方向
            if (sortCol === currentSort) {
                newOrder = sortOrder === 'A' ? 'D' : 'A';
            }

            // 构建新URL
            const newUrl = new URL(window.location);
            newUrl.searchParams.set('C', currentSort);
            newUrl.searchParams.set('O', newOrder);

            // 跳转到新URL
            window.location.href = newUrl.toString();
        });
    });

    // 找到当前排序列
    const colMap = {'N': 0, 'S': 1, 'M': 2};
    const activeIndex = colMap[sortCol];

    if (activeIndex !== undefined && headers[activeIndex]) {
        // 设置活动状态
        headers[activeIndex].classList.add('active-sort');

        // 设置箭头方向
        const indicator = headers[activeIndex].querySelector('.sort-indicator');
        if (indicator) {
            indicator.textContent = sortOrder === 'A' ? '↑' : '↓';
        }
    }
}

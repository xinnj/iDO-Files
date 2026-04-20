/* Toast Notification System */

function showToast(message, type = 'info') {
    let container = document.querySelector('.toast-container');
    if (!container) {
        container = document.createElement('div');
        container.className = 'toast-container';
        document.body.appendChild(container);
    }

    const toast = document.createElement('div');
    toast.className = `toast ${type}`;

    const icons = {
        success: 'ti-check',
        error: 'ti-x',
        warning: 'ti-alert-triangle',
        info: 'ti-info-circle'
    };

    toast.innerHTML = `
        <i class="ti ${icons[type] || icons.info} toast-icon"></i>
        <span class="toast-message">${message}</span>
    `;

    container.appendChild(toast);

    setTimeout(() => {
        toast.style.opacity = '0';
        setTimeout(() => toast.remove(), 300);
    }, 4000);
}

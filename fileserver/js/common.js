// Show success message
function showSuccess(message) {
    const el = document.getElementById('notificationAlert');
    el.classList.remove('alert-danger', 'alert-info', 'd-none');
    el.classList.add('alert-success');
    document.getElementById('notificationMessage').textContent = message;

    setTimeout(() => {
        el.classList.add('d-none');
    }, 5000);
}

// Show error message
function showError(message) {
    const el = document.getElementById('notificationAlert');
    el.classList.remove('alert-success', 'alert-info', 'd-none');
    el.classList.add('alert-danger');
    document.getElementById('notificationMessage').textContent = message;
    setTimeout(() => {
        el.classList.add('d-none');
    }, 10000);
}

// Show info message
function showInfo(message) {
    const el = document.getElementById('notificationAlert');
    el.classList.remove('alert-success', 'alert-danger', 'd-none');
    el.classList.add('alert-info');
    document.getElementById('notificationMessage').textContent = message;

    setTimeout(() => {
        el.classList.add('d-none');
    }, 3000);
}

function clearMessages() {
    let el = document.getElementById('notificationAlert');
    if (el) el.classList.add('d-none');
}
class QRCodeGenerator {
    constructor(qrCodeElement) {
        this.qrCodeElement = qrCodeElement;
        this.expiredMinutes = null;
        this.type = qrCodeElement.getAttribute("type");
        this.manifestUrl = qrCodeElement.getAttribute("path");
        this.shareToken = qrCodeElement.getAttribute("share-token");
        this.qrCodeId = qrCodeElement.id || `qrcode-${Math.random().toString(36).substr(2, 9)}`;
        this.detectLanguage();
    }

    detectLanguage() {
        const browserLang = navigator.language || navigator.userLanguage;
        this.isChinese = browserLang.toLowerCase().includes('zh') || browserLang.toLowerCase().includes('cn');
    }

    setGenerationTime() {
        sessionStorage.setItem(`${this.qrCodeId}_generatedTime`, new Date().getTime());
    }

    isQRCodeExpired() {
        const generatedTime = sessionStorage.getItem(`${this.qrCodeId}_generatedTime`);
        if (!generatedTime) return true;

        const currentTime = new Date().getTime();
        return (currentTime - parseInt(generatedTime)) > (this.expiredMinutes - 1) * 60 * 1000;
    }

    showExpiredOnQRCode() {
        const existingOverlay = this.qrCodeElement.querySelector(".expired-overlay");
        if (existingOverlay) {
            existingOverlay.remove();
        }

        // Create a container for the overlay
        const container = document.createElement("div");
        container.style.position = "relative";
        container.style.width = "200px";
        container.style.height = "200px";
        container.style.margin = "0 auto";

        // Move existing content to container
        while (this.qrCodeElement.firstChild) {
            container.appendChild(this.qrCodeElement.firstChild);
        }

        const overlay = document.createElement("div");
        overlay.className = "expired-overlay";
        overlay.style.position = "absolute";
        overlay.style.top = "0";
        overlay.style.left = "0";
        overlay.style.width = "100%";
        overlay.style.height = "100%";
        overlay.style.backgroundColor = "rgba(255, 255, 255, 0.8)";
        overlay.style.display = "flex";
        overlay.style.flexDirection = "column";
        overlay.style.justifyContent = "center";
        overlay.style.alignItems = "center";
        overlay.style.zIndex = "10";

        const expiredText = document.createElement("div");
        expiredText.textContent = this.isChinese ? "已过期" : "Expired";
        expiredText.style.fontSize = "24px";
        expiredText.style.fontWeight = "bold";
        expiredText.style.color = "#ff0000";
        expiredText.style.marginBottom = "8px";
        expiredText.style.textAlign = "center";

        const refreshText = document.createElement("div");
        refreshText.textContent = this.isChinese ? "请刷新页面" : "Please refresh the page";
        refreshText.style.fontSize = "16px";
        refreshText.style.color = "#333";
        refreshText.style.textAlign = "center";

        overlay.appendChild(expiredText);
        overlay.appendChild(refreshText);

        container.appendChild(overlay);
        this.qrCodeElement.appendChild(container);

        // Remove installation instruction when expired
        const existingInstruction = this.qrCodeElement.querySelector(".install-instruction");
        if (existingInstruction) {
            existingInstruction.remove();
        }
    }

    startExpirationCheck() {
        this.setGenerationTime();

        // Create countdown display
        this.countdownElement = document.createElement("div");
        this.countdownElement.className = "qr-countdown";
        this.countdownElement.style.position = "absolute";
        this.countdownElement.style.top = "-30px";
        this.countdownElement.style.left = "50%";
        this.countdownElement.style.transform = "translateX(-50%)";
        this.countdownElement.style.backgroundColor = "rgba(0, 0, 0, 0.7)";
        this.countdownElement.style.color = "#fff";
        this.countdownElement.style.padding = "4px 8px";
        this.countdownElement.style.borderRadius = "4px";
        this.countdownElement.style.fontSize = "12px";
        this.countdownElement.style.fontWeight = "600";
        this.countdownElement.style.fontFamily = '"JetBrains Mono", "SF Mono", Menlo, Monaco, Consolas, monospace';
        this.countdownElement.style.zIndex = "5";
        this.qrCodeElement.appendChild(this.countdownElement);

        // Update countdown every second
        this.updateCountdown();
        this.countdownInterval = setInterval(() => {
            if (this.isQRCodeExpired()) {
                this.showExpiredOnQRCode();
                if (this.countdownElement) {
                    this.countdownElement.remove();
                }
                clearInterval(this.countdownInterval);
            } else {
                this.updateCountdown();
            }
        }, 1000);
    }

    updateCountdown() {
        const generatedTime = parseInt(sessionStorage.getItem(`${this.qrCodeId}_generatedTime`));
        if (!generatedTime) return;

        const currentTime = new Date().getTime();
        const expiredTime = generatedTime + (this.expiredMinutes - 1) * 60 * 1000;
        const remainingTime = Math.max(0, expiredTime - currentTime);

        const minutes = Math.floor(remainingTime / 60000);
        const seconds = Math.floor((remainingTime % 60000) / 1000);

        if (remainingTime <= 0) {
            this.countdownElement.textContent = this.isChinese ? "已过期" : "Expired";
            this.countdownElement.style.backgroundColor = "rgba(255, 0, 0, 0.8)";
        } else {
            const timeText = `${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
            const label = this.isChinese ? `剩余 ${timeText}` : `${timeText} left`;
            this.countdownElement.textContent = label;
        }
    }

    async generateQRCode() {
        try {
            let actionUrl;
            const params = new URLSearchParams();
            params.append('path', this.manifestUrl);
            if (this.shareToken) {
                params.append('share-token', this.shareToken);
            }

            const response = await fetch(teamUrl + 'fileserver/gen-time-token?' + params.toString());
            const data = await response.json();
            const token = data['token'];
            this.expiredMinutes = data['expiredMinutes'];

            switch (this.type) {
                case "ios":
                    actionUrl = 'itms-services://?action=download-manifest&amp;url=' + teamUrl + 'app/' + token;
                    break;
                case "hos":
                    const buttonClickUrl = 'store://enterprise/manifest?url=' + teamUrl + 'app/' + token + '.json5';
                    const manifestFile = this.manifestUrl.split('/').filter(Boolean).pop();
                    actionUrl = teamUrl + 'fileserver/app-install.html' + '?install=' + buttonClickUrl + '&manifest=' + manifestFile;
                    break;
                case "android":
                    actionUrl = teamUrl + 'app/' + token;
                    break;
                default:
                    console.error("Unknown type:", this.type);
            }

            new QRCode(this.qrCodeElement, {
                text: actionUrl,
                width: 200,
                height: 200,
                colorDark: "#000000",
                colorLight: "#ffffff",
                correctLevel: QRCode.CorrectLevel.M
            });

            this.qrCodeElement.style.position = "relative";

            // Add installation instruction
            const instruction = document.createElement("div");
            instruction.className = "install-instruction";
            if (this.type === "ios") {
                instruction.innerHTML = this.isChinese
                    ? "使用iOS相机应用扫描二维码<br><small style='color: #888;'>扫描后点击<strong style='color: #007AFF; font-weight: 600;'>在 iTunes 中打开</strong></small>"
                    : "Scan with iOS Camera app<br><small style='color: #888;'>Click <strong style='color: #007AFF; font-weight: 600;'>Open in iTunes</strong> after scanning</small>";
                this.qrCodeElement.appendChild(instruction);
            }
            if (this.type === "hos" || this.type === "android") {
                instruction.innerHTML = this.isChinese
                    ? "使用系统浏览器扫描二维码"
                    : "Scan with system browser";
                this.qrCodeElement.appendChild(instruction);
            }

            this.startExpirationCheck();
        } catch (error) {
            console.error("Can't generate QR code: ", error);
        }
    }
}

function removeEmptyRows() {
    const qrCodeElements = document.querySelectorAll('.qrcode');
    let hasShareToken = false;

    qrCodeElements.forEach(element => {
        const shareToken = element.getAttribute('share-token');
        if (shareToken && shareToken.trim() !== '') {
            hasShareToken = true;
        }
    });

    if (hasShareToken) {
        const rows = document.querySelectorAll('.container .row');
        rows.forEach(row => {
            const rightColumn = row.querySelector('.right-column');
            if (rightColumn) {
                const textContent = rightColumn.textContent.trim();
                const hasElements = rightColumn.querySelectorAll('*').length > 0;

                if (!textContent && !hasElements) {
                    row.remove();
                }
            }
        });
    }
}

function initializeAllQRCodes() {
    const qrCodeElements = document.querySelectorAll('.qrcode');
    const qrCodeGenerators = [];

    qrCodeElements.forEach(element => {
        const generator = new QRCodeGenerator(element);
        qrCodeGenerators.push(generator);
        generator.generateQRCode();
    });

    return qrCodeGenerators;
}

const currentUrl = new URL(window.location.href);
const teamUrl = currentUrl.protocol + '//' + currentUrl.host + '<URL_PREFIX>';

window.addEventListener('DOMContentLoaded', () => {
    removeEmptyRows();
    initializeAllQRCodes();
});
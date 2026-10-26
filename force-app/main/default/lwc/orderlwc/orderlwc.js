import { LightningElement } from 'lwc';
import getCatalogue from '@salesforce/apex/OMSCatalogueController.getCatalogue';
import getAccounts from '@salesforce/apex/OMSCatalogueController.getAccounts';
import isPriceOverrideAllowed from '@salesforce/apex/OMSCheckoutController.isPriceOverrideAllowed';
import checkPrice from '@salesforce/apex/OMSCheckoutController.checkPrice';
import checkout from '@salesforce/apex/OMSCheckoutController.checkout';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

const PAGE_SIZE = 20;

export default class OmsProductCatalogue extends LightningElement {
    products = [];
    columns = [];
    familyFilterEnabled = true;
    familyOptions = [{ label: 'All Families', value: '' }];
    accountOptions = [{ label: '-- Select an Account --', value: '' }];
    accountRows = [];
    cartItems = [];
    searchText = '';
    selectedFamily = '';
    sortValue = 'nameAsc';
    pageNumber = 1;
    totalRecords = 0;
    isLoading = false;
    isWorking = false;
    errorMessage = '';
    accountSearch = '';
    selectedAccountId = '';
    quantityByProductId = {};
    isManager = false;
    searchTimer;
    accountSearchTimer;
    catalogueRequestId = 0;
    accountRequestId = 0;

    connectedCallback() {
        this.loadCatalogue();
        this.loadAccounts();
        this.loadManagerPermission();
    }

    disconnectedCallback() {
        clearTimeout(this.searchTimer);
        clearTimeout(this.accountSearchTimer);
    }

    get totalPages() {
        return Math.max(1, Math.ceil(this.totalRecords / PAGE_SIZE));
    }
    get isFirstPage() {
        return this.pageNumber <= 1;
    }
    get isLastPage() {
        return this.pageNumber >= this.totalPages;
    }
    get showFamilyFilter() {
        return this.familyFilterEnabled;
    }
    get hasProducts() {
        return this.products.length > 0;
    }
    get hasCartItems() {
        return this.cartItems.length > 0;
    }
    get cartCount() {
        return this.cartItems.length;
    }
    get cartSubtotal() {
        return this.cartItems.reduce((sum, item) => sum + item.lineTotal, 0);
    }
    get sortOptions() {
        return [
            { label: 'Name (A–Z)', value: 'nameAsc' },
            { label: 'Name (Z–A)', value: 'nameDesc' },
            { label: 'Price (Low to High)', value: 'priceAsc' },
            { label: 'Price (High to Low)', value: 'priceDesc' }
        ];
    }

    async loadCatalogue() {
        clearTimeout(this.searchTimer);
        const requestId = ++this.catalogueRequestId;
        this.isLoading = true;
        this.errorMessage = '';

        const sortMap = {
            nameAsc: { sortBy: 'Name', sortAscending: true },
            nameDesc: { sortBy: 'Name', sortAscending: false },
            priceAsc: { sortBy: 'price', sortAscending: true },
            priceDesc: { sortBy: 'price', sortAscending: false }
        };

        try {
            const result = await getCatalogue({
                searchText: this.searchText,
                familyFilter: this.selectedFamily,
                sortBy: sortMap[this.sortValue].sortBy,
                sortAscending: sortMap[this.sortValue].sortAscending,
                pageNumber: this.pageNumber,
                pageSize: PAGE_SIZE
            });

            // Ignore older responses if the user has already changed the search/filter.
            if (requestId !== this.catalogueRequestId) return;

            this.totalRecords = result?.totalRecords || 0;
            this.columns = (result?.columns || []).filter((column) => column.fieldName !== 'Name');
            this.familyFilterEnabled = result?.familyFilterEnabled !== false;
            if (!this.familyFilterEnabled) this.selectedFamily = '';
            this.familyOptions = [
                { label: 'All Families', value: '' },
                ...(result?.families || []).map((value) => ({ label: value, value }))
            ];

            this.products = (result?.products || []).map((row) => {
                const name = row.name || row.Name || row.configuredValues?.Name || 'Unnamed Product';
                const cells = this.columns.map((column) => ({
                    key: `${row.id}-${column.fieldName}`,
                    value: row.configuredValues?.[column.fieldName] ?? ''
                }));
                return {
                    ...row,
                    name,
                    unitPrice: row.unitPrice === null || row.unitPrice === undefined
                        ? null : Number(row.unitPrice),
                    minimumQuantity: Number(row.minimumQuantity || 1),
                    maximumQuantity: row.maximumQuantity === null || row.maximumQuantity === undefined
                        ? null : Number(row.maximumQuantity),
                    hasUnitPrice: row.unitPrice !== null && row.unitPrice !== undefined,
                    cells,
                    requestedQuantity: this.quantityByProductId[row.id] ?? row.minimumQuantity ?? 1
                };
            });
        } catch (error) {
            if (requestId !== this.catalogueRequestId) return;
            this.products = [];
            this.errorMessage = this.getErrorMessage(error);
        } finally {
            if (requestId === this.catalogueRequestId) this.isLoading = false;
        }
    }

    async loadAccounts() {
        const requestId = ++this.accountRequestId;
        try {
            const rows = await getAccounts({ searchText: this.accountSearch });
            if (requestId !== this.accountRequestId) return;
            this.accountRows = rows || [];
            this.accountOptions = [
                { label: '-- Select an Account --', value: '' },
                ...this.accountRows.map((account) => ({
                    label: account.Name + (account.ERP_Customer_ID__c ? '' : ' (Missing ERP Customer ID)'),
                    value: account.Id
                }))
            ];
        } catch (error) {
            if (requestId === this.accountRequestId) {
                this.showToast('Account search failed', this.getErrorMessage(error), 'error');
            }
        }
    }

    async loadManagerPermission() {
        try {
            this.isManager = await isPriceOverrideAllowed();
        } catch (error) {
            this.isManager = false;
        }
    }

    handleSearchChange(event) {
        this.searchText = event.target.value || '';
        this.pageNumber = 1;
        clearTimeout(this.searchTimer);
        this.searchTimer = setTimeout(() => this.loadCatalogue(), 300);
    }
    handleFamilyChange(event) {
        clearTimeout(this.searchTimer);
        this.selectedFamily = event.detail.value;
        this.pageNumber = 1;
        this.loadCatalogue();
    }
    handleSortChange(event) {
        clearTimeout(this.searchTimer);
        this.sortValue = event.detail.value;
        this.pageNumber = 1;
        this.loadCatalogue();
    }
    handlePrevious() {
        if (!this.isFirstPage) {
            this.pageNumber -= 1;
            this.loadCatalogue();
        }
    }
    handleNext() {
        if (!this.isLastPage) {
            this.pageNumber += 1;
            this.loadCatalogue();
        }
    }

    handleQuantityChange(event) {
        const id = event.target.dataset.id;
        const quantity = Number(event.target.value);
        this.quantityByProductId = { ...this.quantityByProductId, [id]: quantity };
        this.products = this.products.map((product) => product.id === id
            ? { ...product, requestedQuantity: quantity } : product);
    }

    async handleAddToCart(event) {
        const id = event.currentTarget.dataset.id;
        const product = this.products.find((row) => row.id === id);
        if (!product) return;

        const quantity = Number(this.quantityByProductId[id] ?? product.requestedQuantity);
        const minimum = Number(product.minimumQuantity ?? 1);
        const maximum = product.maximumQuantity === null || product.maximumQuantity === undefined
            ? null : Number(product.maximumQuantity);

        if (!Number.isInteger(quantity) || quantity < 1) {
            this.showToast('Invalid quantity', 'Enter a whole number greater than zero.', 'error');
            return;
        }
        // A missing maximum is treated as no upper limit; Apex applies the same rule at checkout.
        if (product.maximumQuantity !== null && product.maximumQuantity !== undefined &&
            Number.isFinite(maximum) && quantity > maximum) {
            this.showToast('Quantity too high', `Maximum quantity for this product is ${maximum}.`, 'error');
            return;
        }
        if (quantity < minimum) {
            this.showToast('Quantity too low', `Minimum quantity for this product is ${minimum}.`, 'error');
            return;
        }

        this.isWorking = true;
        try {
            // ERP price is checked as the product is added to the cart.
            const priceResult = await checkPrice({ productId: product.id });
            const price = priceResult.unitPrice;
            if (price === null || price === undefined) {
                this.showToast('Price unavailable', 'No ERP or local fallback price is available.', 'error');
                return;
            }

            const existing = this.cartItems.find((item) => item.id === id);
            const item = {
                id,
                name: product.name || product.Name || 'Unnamed Product',
                productCode: product.productCode || '',
                quantity,
                baseUnitPrice: Number(price),
                unitPrice: Number(price),
                priceSource: priceResult.priceSource,
                basePriceSource: priceResult.priceSource,
                fallback: priceResult.priceSource === 'Local',
                fallbackReason: priceResult.fallbackReason || '',
                rowClass: priceResult.priceSource === 'Local' ? 'fallback-row' : '',
                overridePrice: '',
                overrideReason: '',
                minimumQuantity: minimum,
                maximumQuantity: maximum,
                lineTotal: quantity * Number(price)
            };
            this.cartItems = existing
                ? this.cartItems.map((oldItem) => oldItem.id === id ? item : oldItem)
                : [...this.cartItems, item];

            if (item.fallback) {
                this.showToast('Fallback price used', item.fallbackReason || 'ERP price was unavailable; local price is being used.', 'warning');
            } else {
                this.showToast('Added to cart', `${product.name || product.Name || 'Product'} was added using the ERP price.`, 'success');
            }
        } catch (error) {
            this.showToast('Could not add product', this.getErrorMessage(error), 'error');
        } finally {
            this.isWorking = false;
        }
    }

    handleRemoveFromCart(event) {
        const id = event.currentTarget.dataset.id;
        this.cartItems = this.cartItems.filter((item) => item.id !== id);
    }

    handleOverridePriceChange(event) {
        const id = event.target.dataset.id;
        const value = event.target.value;
        this.cartItems = this.cartItems.map((item) => {
            if (item.id !== id) return item;
            const override = value === '' ? '' : Number(value);
            const unitPrice = override === '' ? item.baseUnitPrice : override;
            const usingFallback = override === '' && item.basePriceSource === 'Local';
            return {
                ...item,
                overridePrice: value,
                unitPrice,
                priceSource: override === '' ? item.basePriceSource : 'Override',
                fallback: usingFallback,
                rowClass: usingFallback ? 'fallback-row' : '',
                lineTotal: item.quantity * unitPrice
            };
        });
    }

    handleCartQuantityChange(event) {
        const id = event.target.dataset.id;
        const quantity = event.target.value === '' ? 0 : Number(event.target.value);
        this.cartItems = this.cartItems.map((item) => item.id === id
            ? { ...item, quantity, lineTotal: Number.isFinite(quantity) ? quantity * item.unitPrice : 0 } : item);
    }

    handleOverrideReasonChange(event) {
        const id = event.target.dataset.id;
        const value = event.target.value;
        this.cartItems = this.cartItems.map((item) => item.id === id
            ? { ...item, overrideReason: value } : item);
    }

    handleAccountSearchChange(event) {
        this.accountSearch = event.target.value || '';
        clearTimeout(this.accountSearchTimer);
        this.accountSearchTimer = setTimeout(() => this.loadAccounts(), 300);
    }
    handleAccountChange(event) {
        this.selectedAccountId = event.detail.value;
    }

    async handleRecheckPrices() {
        if (!this.cartItems.length) {
            this.showToast('Empty cart', 'Add a product before checking prices.', 'warning');
            return;
        }
        this.isWorking = true;
        try {
            const updated = [];
            for (const item of this.cartItems) {
                const result = await checkPrice({ productId: item.id });
                if (result.unitPrice === null || result.unitPrice === undefined) {
                    throw new Error(`No ERP or local price is available for ${item.name}.`);
                }
                const useOverride = this.isManager && item.overridePrice !== '' &&
                    item.overridePrice !== null && item.overridePrice !== undefined;
                const baseUnitPrice = Number(result.unitPrice);
                const unitPrice = useOverride ? Number(item.overridePrice) : baseUnitPrice;
                const fallback = !useOverride && result.priceSource === 'Local';
                updated.push({
                    ...item,
                    baseUnitPrice,
                    unitPrice,
                    priceSource: useOverride ? 'Override' : result.priceSource,
                    basePriceSource: result.priceSource,
                    fallback,
                    fallbackReason: result.fallbackReason || '',
                    rowClass: fallback ? 'fallback-row' : '',
                    lineTotal: item.quantity * unitPrice
                });
            }
            this.cartItems = updated;
            this.showToast('Prices checked', 'Cart prices have been refreshed. Review any changed prices before checkout.', 'success');
        } catch (error) {
            this.showToast('Price check failed', this.getErrorMessage(error), 'error');
        } finally {
            this.isWorking = false;
        }
    }

    async handleCheckout() {
        if (!this.selectedAccountId) {
            this.showToast('Account required', 'Select an Account before checkout.', 'error');
            return;
        }
        if (!this.cartItems.length) {
            this.showToast('Empty cart', 'Add at least one product before checkout.', 'error');
            return;
        }

        for (const item of this.cartItems) {
            if (!Number.isInteger(item.quantity) || item.quantity < 1 || item.quantity < item.minimumQuantity ||
                (item.maximumQuantity !== null && item.maximumQuantity !== undefined && item.quantity > item.maximumQuantity)) {
                this.showToast('Quantity validation failed', `Check the quantity for ${item.name}.`, 'error');
                return;
            }
            const hasOverride = item.overridePrice !== '' && item.overridePrice !== null &&
                item.overridePrice !== undefined;
            if (hasOverride && !this.isManager) {
                this.showToast('Not permitted', 'Only a Sales Manager can override a price.', 'error');
                return;
            }
            if (hasOverride && (!item.overrideReason || !item.overrideReason.trim())) {
                this.showToast('Override reason required', `Enter a reason for the override on ${item.name}.`, 'error');
                return;
            }
            if (hasOverride && (!Number.isFinite(Number(item.overridePrice)) || Number(item.overridePrice) < 0)) {
                this.showToast('Invalid override price', `Enter a valid non-negative price for ${item.name}.`, 'error');
                return;
            }
        }

        this.isWorking = true;
        try {
            const request = {
                accountId: this.selectedAccountId,
                items: this.cartItems.map((item) => ({
                    productId: item.id,
                    quantity: item.quantity,
                    expectedUnitPrice: item.baseUnitPrice,
                    overridePrice: item.overridePrice === '' ? null : Number(item.overridePrice),
                    overrideReason: item.overrideReason || ''
                }))
            };
            const result = await checkout({ requestJson: JSON.stringify(request) });

            if (result.priceChanged) {
                this.cartItems = this.cartItems.map((item) => {
                    const changed = (result.updatedPrices || []).find((price) => price.productId === item.id);
                    if (!changed) return item;
                    if (changed.unitPrice === null || changed.unitPrice === undefined) return item;
                    const baseUnitPrice = Number(changed.unitPrice);
                    const hasOverride = item.overridePrice !== '' && item.overridePrice !== null && item.overridePrice !== undefined;
                    const unitPrice = hasOverride ? Number(item.overridePrice) : baseUnitPrice;
                    const fallback = !hasOverride && changed.priceSource === 'Local';
                    return {
                        ...item,
                        baseUnitPrice,
                        unitPrice,
                        priceSource: hasOverride ? 'Override' : changed.priceSource,
                        basePriceSource: changed.priceSource,
                        fallback,
                        fallbackReason: changed.fallbackReason || '',
                        rowClass: fallback ? 'fallback-row' : '',
                        lineTotal: item.quantity * unitPrice
                    };
                });
                this.showToast('Price changed', 'ERP prices changed during checkout. Review the updated cart and click Checkout again.', 'warning');
                return;
            }

            this.showToast('Order created', `Order ${result.orderNumber || result.orderId} was created.`, 'success');
            this.cartItems = [];
            this.quantityByProductId = {};
            this.selectedAccountId = '';
        } catch (error) {
            this.showToast('Checkout failed', this.getErrorMessage(error), 'error');
        } finally {
            this.isWorking = false;
        }
    }

    getErrorMessage(error) {
        if (error?.body?.message) return error.body.message;
        if (error?.message) return error.message;
        return 'Unexpected error. Check Apex debug logs and field configuration.';
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
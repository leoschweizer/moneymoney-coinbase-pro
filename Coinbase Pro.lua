-- Inofficial Coinbase Pro Extension (https://pro.coinbase.com/) for MoneyMoney
-- Fetches balances via Coinbase Pro API and returns them as securities
--
-- Username: Coinbase Pro API Key
-- Username2: Coinbase Pro API Secret
-- Password: Coinbase Pro API Passphrase
--
-- Copyright (c) 2017 Leo Schweizer
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

WebBanking {
        version = 2.0,
        url = "https://api.pro.coinbase.com",
        description = "Fetch balances via Coinbase Pro API and list them as securities",
        services = { "Coinbase Pro" }
}

local apiKey
local apiSecret
local apiPassphrase

local nativeCurrency = "EUR"
local market = "Coinbase Pro"

function SupportsBank (protocol, bankCode)
        return protocol == ProtocolWebBanking and bankCode == "Coinbase Pro"
end

function InitializeSession (protocol, bankCode, username, username2, password, username3)
        apiKey = username
        apiSecret = username2
        apiPassphrase = password
end

function ListAccounts (knownAccounts)
        local account = {
                name = market,
                accountNumber = "Main",
                currency = nativeCurrency,
                portfolio = true,
                type = "AccountTypePortfolio"
        }
        return {account}
end

function RefreshAccount (account, since)
        local s = {}
        local balances = queryCoinbaseProApi("accounts")
        local products = queryCoinbaseProApi("products")
        local orders = {}

        -- Fetch pages of 100 orders, iterate through them page by page until cb-after header is unset
        after = "start"
        while after ~= nil do
                if after == "start" then
                        orders_data, headers = queryCoinbaseProApi("orders?&status=done")
                else
                        orders_data, headers = queryCoinbaseProApi("orders?after=" .. after .. "&status=done")
                end
                -- Set our next page to cb-after header
                after = headers["cb-after"]
                -- Merge new results
                orders = merge(orders, orders_data)
        end

        -- Match orders to our balances
        for _, balance_data in pairs(balances) do
                local after = nil
                local crypto_shorthandle = balance_data["currency"]
                local total_quantity = tonumber(balance_data["balance"])
                local price = 1
                local product_id = crypto_shorthandle .. "-" .. nativeCurrency
                local amount = nil
                local bought_quantity = 0
                local transferred_quantity = 0
                local quantity = nil
                local currency = nil
                local order_value = 0.0
                local timestamp = nil
                local latest_timestamp = 0
                local pattern = "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+).%d+Z"

                if crypto_shorthandle ~= nativeCurrency and productsExists(product_id, products) then
                        price = queryExchangeRate(product_id, products)
                        -- Iterate through our orders in reverse, oldest transactions first
                        for i = #orders, 1, -1 do        
                                -- Bought coins
                                if orders[i]["side"] == "buy" and orders[i]["product_id"] == product_id then
                                        bought_quantity = bought_quantity + orders[i]["filled_size"]
                                        -- We have to generate a proper timestamp for MoneyMoney
                                        year, month, day, hour, min, sec = orders[i]["done_at"]:match(pattern)
                                        timestamp = os.time({day=day,month=month,year=year,hour=hour,min=min,sec=sec})
                                        if timestamp > latest_timestamp then
                                                latest_timestamp = timestamp
                                        end
                                        -- This trades coin value at trade time
                                        if orders[i]["price"] ~= nil then
                                                order_value = order_value + (orders[i]["price"] * orders[i]["filled_size"])
                                        else
                                                order_value = order_value + (1 / orders[i]["filled_size"] * orders[i]["executed_value"] * orders[i]["filled_size"])
                                        end
                                end
                                -- Sold coins
                                if orders[i]["side"] == "sell" and orders[i]["product_id"] == product_id then
                                        bought_quantity = bought_quantity - orders[i]["filled_size"]
                                        -- We have to generate a proper timestamp for MoneyMoney
                                        year, month, day, hour, min, sec = orders[i]["done_at"]:match(pattern)
                                        timestamp = os.time({day=day,month=month,year=year,hour=hour,min=min,sec=sec})
                                        if timestamp > latest_timestamp then
                                                latest_timestamp = timestamp
                                        end
                                        -- Value of coins is average value of all coins at sell time
                                        order_value = order_value - (order_value * orders[i]["filled_size"])
                                end
                        end
                        -- Add unknown quantities of coins as current purchase price
                        transferred_quantity = total_quantity - bought_quantity
                        order_value = order_value + (price * transferred_quantity)

                        -- Weighted average order price of all orders
                        if total_quantity > 0 then
                                order_value = order_value / total_quantity
                        else
                                order_value = 0
                        end

                        -- Securities
                        s[#s+1] = {
                                tradeTimestamp = timestamp,
                                name = crypto_shorthandle,
                                market = market,
                                quantity = total_quantity,
                                currency = currency,
                                price = price,
                                purchasePrice = order_value,
                                amount = total_quantity * price
                        }
                else
                        -- A native currency, not a crypto coin
                        quantity = nil
                        price = nil
                        currency = nativeCurrency
                        amount = total_quantity
                end
        end
        return {securities = s}
end

function EndSession ()
end

function base64decode(data)
        local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
        data = string.gsub(data, '[^'..b..'=]', '')
        return (data:gsub('.', function(x)
                if (x == '=') then return '' end
                local r,f='',(b:find(x)-1)
                for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
                return r;
        end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
                if (#x ~= 8) then return '' end
                local c=0
                for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
                return string.char(c)
        end))
end

function queryCoinbaseProApi(endpoint)
        -- if we run into too many requests we need to uncomment this
        -- sleep(1)
        local path = string.format("/%s", endpoint)
        local timestamp = string.format("%d", MM.time())
        local apiSign = MM.hmac256(base64decode(apiSecret), timestamp .. "GET" .. path)

        local headers = {}
        headers["CB-ACCESS-KEY"] = apiKey
        headers["CB-ACCESS-TIMESTAMP"] = timestamp
        headers["CB-ACCESS-SIGN"] = MM.base64(apiSign)
        headers["CB-ACCESS-PASSPHRASE"] = apiPassphrase

        content, charset, mimeType, filename, rem_headers = Connection():request("GET", url .. path, nil, nil, headers)
        return JSON(content):dictionary(), rem_headers
end

function queryExchangeRate(product_id, products)
        ticker = queryCoinbaseProApi("products/" .. product_id .. "/ticker")
        -- sometimes newly added coins have no prices in ticket yet, then we have to use something else
        if ticker["price"] then
                return ticker["price"]
        else
                return ticker["bid"]
        end
end

function productsExists(product_id, products)
        for _, data in pairs(products) do
                if data["id"] == product_id then return true end
        end
        return false
end

-- Sleep function
local clock = os.clock
function sleep(n)  -- seconds
  local t0 = clock()
  while clock() - t0 <= n do end
end

-- Merge two tables: https://stackoverflow.com/a/29133654
function merge(a, b)
        if type(a) == 'table' and type(b) == 'table' then
                for k,v in pairs(b) do if type(v)=='table' and type(a[k] or false)=='table' then merge(a[k],v) else a[k]=v end end
        end
        return a
end
-- SIGNATURE: MCwCFFrI1B5aenRMx/jAkWnJLKRDWkq3AhQusomTlSPK5Kv7yq7HFc9PCyIXjg==

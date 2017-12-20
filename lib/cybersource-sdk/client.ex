defmodule CyberSourceSDK.Client do
  @moduledoc """
  This Client module handle all HTTPS requests to the CyberSource server. It
  takes some parameters and convert to HTTPS request.

  It support the following payments:
  * Android Pay
  * Apple Pay

  It supports the following requests:
  * Authorization
  * Capture
  * Refund
  """

  import SweetXml

  alias CyberSourceSDK.Helper

  @doc """
  Create an authorization payment

  For a normal account, bill_to is mandatory. If you ask CyberSource for a
  relaxed AVS check, bill_to can be optional.

  # Example

  Without `bill_to` and `worker` parameters

  ```
  authorize(32.0, "1234", "VISA", "oJ8IOx6SA9HNncxzpS9akm32n+DSAJH==")
  ```

  With `bill_to` parameter

  ```
  bill_to = CyberSourceSDK.bill_to("John", "Doe", "Marylane Street", "34", "New York", "Hong Kong", "john@example.com")
  authorize(32.0, "1234", "VISA", "oJ8IOx6SA9HNncxzpS9akm32n+DSAJH==", bill_to)
  ```

  """
  def authorize(price, merchant_reference_code, card_type, encrypted_payment, bill_to \\ [], worker \\ :merchant)

  def authorize(price, merchant_reference_code, card_type, encrypted_payment, bill_to, worker) when is_float(price) do
    case validate_merchant_reference_code(merchant_reference_code) do
      {:error, reason} ->
        {:error, reason}

      merchant_reference_code_validated ->
        case check_payment_type(encrypted_payment) do
          {:ok, :apple_pay} ->
            pay_with_apple_pay(price, merchant_reference_code_validated, card_type, encrypted_payment, bill_to, worker)

          {:ok, :android_pay} ->
            pay_with_android_pay(price, merchant_reference_code_validated, card_type, encrypted_payment, bill_to, worker)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def authorize(_, _, _, _, _, _) do
    {:error, :price_needs_to_be_float}
  end

  @doc """
  Capture authorization on user credit card
  """
  def capture(order_id, request_id, items \\ [], worker \\ :merchant) do
    replace_params = get_configuration_params(worker)
      ++ [request_id: request_id, reference_id: order_id]
      ++ items

    EEx.eval_file(get_template("capture_request.xml"), assigns: replace_params)
    |> call
  end

  @doc """
  Remove authorization on user credit card

  # Example

  ```
  refund("1234", 23435465442432, items)
  ```
  """
  def refund(order_id, request_id, items \\ [], worker \\ :merchant) do
    # TODO: might need request_token
    replace_params = get_configuration_params(worker)
      ++ [request_id: request_id, reference_id: order_id]
      ++ items

    EEx.eval_file(get_template("refund_request.xml"), assigns: replace_params)
    |> call

    #|> String.replace("\r", "")
    #|> String.replace("\n", "")
    #|> String.replace("\t", "")
  end

  @doc """
  Make a request to pay with Android Pay

  Returns `{:ok, response_object}` , `{:error, :card_type_not_found` or
   `{:error, response_code}`
  """
  def pay_with_android_pay(price, merchant_reference_code, card_type, encrypted_payment, bill_to \\ [], worker \\ :merchant) do
    case get_card_type(card_type) do
      nil ->
        {:error, :card_type_not_found}

      card_type ->
        replace_params = get_configuration_params(worker)
        ++ get_payment_params(merchant_reference_code, price, encrypted_payment, card_type)
        ++ bill_to

        EEx.eval_file(get_template("android_pay_request.xml"), assigns: replace_params)
        |> call
    end
  end

  @doc """
  Make a request to pay with Apple Pay

  Returns `{:ok, response_object}` , `{:error, :card_type_not_found` or
   `{:error, response_code}`
  """
  def pay_with_apple_pay(price, merchant_reference_code, card_type, encrypted_payment, request_id, bill_to \\ [], worker \\ :merchant) do
    case get_card_type(card_type) do
        nil ->
          {:error, :card_type_not_found}

        card_type ->
          replace_params = get_configuration_params(worker)
          ++ get_payment_params(merchant_reference_code, price, encrypted_payment, card_type)
          ++ [request_id: request_id]
          ++ bill_to

          EEx.eval_file(get_template("apple_pay_request.xml"), assigns: replace_params)
          |> call()
    end
  end

  # Define path of request templates
  defp get_template(filename) do
    Path.join(__DIR__, "/requests/" <> filename <> ".eex")
  end

  # Get Payment parameters
  defp get_payment_params(order_id, price, encrypted_token, card_type) do
    [
      reference_id: order_id,
      total_amount: price,
      encrypted_payment_data: encrypted_token,
      card_type: card_type
    ]
  end

  # Extract
  defp json_from_base64(base64_string) do
    case Base.decode64(base64_string) do
      {:ok, json} ->
        case Poison.Parser.parse(json) do
          {:ok, json} -> {:ok, Helper.convert_map_to_key_atom(json)}
          {:error, reason} -> {:error, reason}
        end
      _ -> {:error, :bad_base64_encoding}
    end
  end

  defp get_card_type(card_type) do
    case card_type do
      "VISA" -> "001"
      "MASTERCARD" -> "002"
      "AMERICAN EXPRESS" -> "003"
      "DISCOVER" -> "004"
      "JCB" -> nil
      _ -> nil
    end
  end

  defp get_configuration_params(worker) do
    merchant_configuration = Application.get_env(:cybersource_sdk, worker)

    if (!is_nil(merchant_configuration)) do
      [
        merchant_id: Map.get(merchant_configuration, :merchant_id),
        transaction_key: Map.get(merchant_configuration, :transaction_key),
        currency: Map.get(merchant_configuration, :currency),
      ]
    else
      []
    end
  end

  # Make HTTPS request
  defp call(xml_body) do
    endpoint = Application.get_env(:cybersource_sdk, :endpoint)

    # TODO: Check errors
    {:ok,  %HTTPoison.Response{body: response_body}} = HTTPoison.post endpoint, xml_body, [{"Content-Type", "application/xml"}]

    parse_response(response_body)
    |> handle_response
  end

  defp validate_merchant_reference_code(merchant_reference_code) do
    cond do
      String.valid?(merchant_reference_code) && length(merchant_reference_code) -> merchant_reference_code
      is_integer(merchant_reference_code) -> Integer.to_string(merchant_reference_code)
      true -> {:error, :invalid_order_id}
    end
  end

  # Internal function to check what type of payment is:
  #
  # {:ok, :android_pay}
  # {:ok, :apple_pay}
  # {:error, :not_found}
  defp check_payment_type(encrypted_payload) do
    case json_from_base64(encrypted_payload) do
      {:ok, data} ->
        header = Map.get(data, :header)
        signature = Map.get(data, :signature)
        publicKeyHash = Map.get(data, :publicKeyHash)

        cond do
          !is_nil(header) && !is_nil(signature) -> {:ok, :apple_pay}
          !is_nil(publicKeyHash) -> {:ok, :android_pay}
          true -> {:ok, :not_found_payment_type}
        end

      {:error, _reason} -> {:error, :invalid_base64_or_json}
    end
  end

  # Parse response from CyberSource
  defp parse_response(xml) do
    xml |> xmap(
      merchantReferenceCode: ~x"//soap:Envelope/soap:Body/c:replyMessage/c:merchantReferenceCode/text()"s,
      requestID: ~x"//soap:Envelope/soap:Body/c:replyMessage/c:requestID/text()"i,
      decision: ~x"//soap:Envelope/soap:Body/c:replyMessage/c:decision/text()"s,
      reasonCode: ~x"//soap:Envelope/soap:Body/c:replyMessage/c:reasonCode/text()"i,
      requestToken: ~x"//soap:Envelope/soap:Body/c:replyMessage/c:requestToken/text()"s,
      ccAuthReply: [
        ~x".//c:ccAuthReply"o,
        reasonCode: ~x"./c:reasonCode/text()"i,
        amount: ~x"./c:amount/text()"f
      ],
      ccCapctureReply: [
        ~x".//c:ccCapctureReply"o,
        reasonCode: ~x"./c:reasonCode/text()"i,
        amount: ~x"./c:amount/text()"f
      ],
      ccAuthReversalReply: [
        ~x".//c:ccAuthReversalReply"o,
        reasonCode: ~x"./c:reasonCode/text()"i,
        amount: ~x"./c:amount/text()"f
      ]
    )
  end

  defp handle_response(response) do
    case response.decision do
      "ACCEPT" -> {:ok, response}
      "REJECT" -> {:error, response.reasonCode}
    end
  end
end

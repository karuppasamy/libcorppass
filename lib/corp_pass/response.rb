require 'saml'

require 'corp_pass'
require 'corp_pass/user'

module CorpPass
  # The purpose of this class is to retrieve the Subject and User/Third Party Authorization XML Values
  class Response
    include CorpPass::Notification

    AUTH_ACCESS_NAME = 'AuthAccess'.freeze
    TP_AUTH_ACCESS_NAME = 'TPAuthAccess'.freeze

    attr_reader :saml_response
    attr_reader :errors

    def initialize(saml_response)
      @saml_response = saml_response
      @errors = []
      decrypt_assertions
      validate
    end

    def valid?
      errors.empty?
    end

    def success?
      @success ||= begin
                     success = saml_response.success?
                     @errors << "SamlResponse status was not success: #{saml_response.status.to_xml}" unless success
                     success
                   end
    end

    delegate :assertions, to: :saml_response

    def assertion
      assertions.first
    end

    delegate :attribute_statement, to: :assertion

    delegate :subject, to: :assertion

    # Not sure if CorpPass is going to return anything to us here.
    # Leaving it here for now
    def name_id
      @name_id ||= (subject._name_id.try(:value) || decrypt_encrypted_id)
    end

    delegate :attributes, to: :attribute_statement

    def auth_access
      Base64.decode64(attributes.first.attribute_values.first.content)
    end

    def third_party?
      attributes.length > 1
    end

    def tp_auth_access
      return nil unless third_party?
      fail NotImplementedError
    end

    def cp_user
      @cp_user ||= CorpPass::User.new(auth_access)
    end

    def cp_tp_user
      fail NotImplementedError
    end

    delegate :to_xml, to: :saml_response

    delegate :to_s, to: :saml_response

    private

    # Once decrypted, libsaml will clear all the encrypted assertions
    def decrypt_assertions
      if !saml_response.encrypted_assertions.empty?
        saml_response.decrypt_assertions(CorpPass.encryption_key)
        notify(CorpPass::Events::DECRYPTED_ASSERTION, assertion.to_xml)
      end
    end

    def conditions
      assertion.conditions
    end

    def validate
      @errors.concat(saml_response.errors.full_messages)
      # Here we do additional validations that libsaml does not perform
      validate_samlp_response
      success?
      validate_assertion
      @errors.each { |error| notify(CorpPass::Events::RESPONSE_VALIDATION_FAILURE, error) }
    end

    def validate_samlp_response
      validate_destination
      validate_issuer(saml_response.issuer, '<samlp:Response>')
    end

    def validate_single_assertion
      one_assertion = assertions.length == 1
      @errors << "More than one assertions found: #{assertions.length}" unless one_assertion
    end

    def validate_assertion
      validate_single_assertion
      validate_issuer(assertion.issuer, '<saml:Assertion>')
      validate_conditions
      validate_subject_confirmation
      validate_name_id
    end

    def validate_conditions
      @errors.concat(validate_timestamps(conditions.not_before, conditions.not_on_or_after,
                                         'saml:Assertion/saml:Conditions'))
      validate_audiences
    end

    def validate_timestamps(not_before, not_on_or_after, context)
      now = Time.now.utc
      timestamp_errors = []
      if !not_before.nil? && now < not_before
        timestamp_errors << "For #{context}, time now is #{now}, and is before #{conditions.not_before}"
      end
      if !not_on_or_after.nil? && now >= not_on_or_after
        timestamp_errors << "For #{context}, time now is #{now}, and is on or after #{conditions.not_on_or_after}"
      end
      timestamp_errors
    end

    def validate_audiences
      audiences = conditions.audience_restriction.try(:audiences)
      if !audiences.nil? && !audiences.map(&:value).include?(CorpPass.configuration.sp_entity)
        @errors << 'Missing SP entity from audiences'
      end
    end

    def validate_destination
      destination = saml_response.destination
      if !destination.nil? && destination != acs
        @errors << "The destination was #{destination}, but the ACS is at #{acs}"
      end
    end

    def acs
      @acs ||= Saml.provider(CorpPass.configuration.sp_entity).assertion_consumer_service.location
    end

    def validate_subject_confirmation
      subject_confirmations = subject.subject_confirmations
      valid_subject_confirmation = false

      subject_confirmations.each do |subject_confirmation|
        next unless subject_confirmation._method == 'urn:oasis:names:tc:SAML:2.0:cm:bearer'
        subject_confirmation_data = subject_confirmation.subject_confirmation_data
        # Note: CorpPass only does IdP initiated SSO -- so we will never have a `InResponseTo` to validate against
        next unless subject_confirmation_data.recipient == acs
        next unless validate_timestamps(nil, subject_confirmation_data.not_on_or_after, 'SubjectConfirmation').empty?

        valid_subject_confirmation = true
        break
      end

      @errors << 'No valid subject confirmation found' unless valid_subject_confirmation
    end

    def validate_name_id
      if name_id.nil?
        @errors << 'Missing <NameID> or <EncryptedNameID>, or decryption of <EncryptedNameID> has failed'
        return
      end

      unless name_id == cp_user.user_id
        @errors << "<NameID>/<EncryptedNameID> in <saml:Subject> was #{name_id}, "\
                   "but <CPUID> in <AuthAccess> is #{cp_user.user_id}"
      end
    end

    def validate_issuer(issuer, context)
      if !issuer.nil? && issuer != CorpPass.configuration.idp_entity
        @errors << "The issuer for #{context} was #{issuer} but the issuer entity expected should be "\
                   "#{CorpPass.configuration.idp_entity}"
      end
    end

    def decrypt_encrypted_id
      encrypted_id = subject.encrypted_id
      unless encrypted_id.nil?
        decrypted = Saml::Util.decrypt_encrypted_id(encrypted_id, CorpPass.encryption_key)
        notify(CorpPass::Events::DECRYPTED_ID, decrypted.to_xml)
        decrypted.try(:name_id).try(:value)
      end
    end
  end
end

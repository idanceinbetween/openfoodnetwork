require 'spec_helper'

describe Enterprise do
  include AuthenticationWorkflow

  describe "sending emails" do
    describe "on creation" do
      let!(:user) { create_enterprise_user( enterprise_limit: 2 ) }
      let!(:enterprise) { create(:enterprise, owner: user) }

      it "sends a welcome email" do
        expect do
          create(:enterprise, owner: user)
        end.to enqueue_job WelcomeEnterpriseJob
      end
    end
  end

  describe "associations" do
    it { should belong_to(:owner) }
    it { should have_many(:supplied_products) }
    it { should have_many(:distributed_orders) }
    it { should belong_to(:address) }

    it "destroys enterprise roles upon its own demise" do
      e = create(:enterprise)
      u = create(:user)
      u.enterprise_roles.build(enterprise: e).save!

      role = e.enterprise_roles.first
      e.destroy
      EnterpriseRole.where(id: role.id).should be_empty
    end

    xit "destroys supplied products upon destroy" do
      s = create(:supplier_enterprise)
      p = create(:simple_product, supplier: s)

      s.destroy

      Spree::Product.where(id: p.id).should be_empty
    end

    it "destroys relationships upon destroy" do
      e = create(:enterprise)
      e_other = create(:enterprise)
      er1 = create(:enterprise_relationship, parent: e, child: e_other)
      er2 = create(:enterprise_relationship, child: e, parent: e_other)

      e.destroy

      EnterpriseRelationship.where(id: [er1, er2]).should be_empty
    end

    describe "relationships to other enterprises" do
      let(:e) { create(:distributor_enterprise) }
      let(:p) { create(:supplier_enterprise) }
      let(:c) { create(:distributor_enterprise) }

      let!(:er1) { create(:enterprise_relationship, parent_id: p.id, child_id: e.id) }
      let!(:er2) { create(:enterprise_relationship, parent_id: e.id, child_id: c.id) }

      it "finds relatives" do
        e.relatives.should match_array [p, c]
      end

      it "finds relatives_including_self" do
        expect(e.relatives_including_self).to include e
      end

      it "scopes relatives to visible distributors" do
        e.should_receive(:relatives_including_self).and_return(relatives = [])
        relatives.should_receive(:is_distributor).and_return relatives
        e.distributors
      end

      it "scopes relatives to visible producers" do
        e.should_receive(:relatives_including_self).and_return(relatives = [])
        relatives.should_receive(:is_primary_producer).and_return relatives
        e.suppliers
      end
    end

    describe "ownership" do
      let(:u1) { create_enterprise_user }
      let(:u2) { create_enterprise_user }
      let!(:e) { create(:enterprise, owner: u1 ) }

      it "adds new owner to list of managers" do
        expect(e.owner).to eq u1
        expect(e.users).to include u1
        expect(e.users).to_not include u2
        e.owner = u2
        e.save!
        e.reload
        expect(e.owner).to eq u2
        expect(e.users).to include u1, u2
      end

      it "validates ownership limit" do
        expect(u1.enterprise_limit).to be 5
        expect(u1.owned_enterprises(:reload)).to eq [e]
        4.times { create(:enterprise, owner: u1) }
        e2 = create(:enterprise, owner: u2)
        expect {
          e2.owner = u1
          e2.save!
        }.to raise_error ActiveRecord::RecordInvalid, "Validation failed: #{u1.email} is not permitted to own any more enterprises (limit is 5)."
      end
    end
  end

  describe "validations" do
    subject { FactoryBot.create(:distributor_enterprise) }
    it { should validate_presence_of(:name) }
    it { should validate_uniqueness_of(:permalink) }
    it { should ensure_length_of(:description).is_at_most(255) }

    it "requires an owner" do
      expect{
        e = create(:enterprise, owner: nil)
        }.to raise_error ActiveRecord::RecordInvalid, "Validation failed: Owner can't be blank"
    end

    describe "name uniqueness" do
      let(:owner) { create(:user, email: 'owner@example.com') }
      let!(:enterprise) { create(:enterprise, name: 'Enterprise', owner: owner) }

      it "prevents duplicate names for new records" do
        e = Enterprise.new name: enterprise.name
        expect(e).to_not be_valid
        expect(e.errors[:name].first).to include I18n.t('enterprise_name_error', email: owner.email)
      end

      it "prevents duplicate names for existing records" do
        e = create(:enterprise, name: 'foo')
        e.name = enterprise.name
        expect(e).to_not be_valid
        expect(e.errors[:name].first).to include I18n.t('enterprise_name_error', email: owner.email)
      end

      it "does not prohibit the saving of an enterprise with no name clash" do
        enterprise.should be_valid
      end

      it "sets the enterprise contact to the owner by default" do
        enterprise.contact.should eq enterprise.owner
      end
    end

    describe "preferred_shopfront_taxon_order" do
      it "empty strings are valid" do
        enterprise = build(:enterprise, preferred_shopfront_taxon_order: "")
        expect(enterprise).to be_valid
      end

      it "a single integer is valid" do
        enterprise = build(:enterprise, preferred_shopfront_taxon_order: "11")
        expect(enterprise).to be_valid
      end

      it "comma delimited integers are valid" do
        enterprise = build(:enterprise, preferred_shopfront_taxon_order: "1,2,3")
        expect(enterprise).to be_valid
        enterprise = build(:enterprise, preferred_shopfront_taxon_order: "1,22,333")
        expect(enterprise).to be_valid
      end

      it "commas at the beginning and end are disallowed" do
        enterprise = build(:enterprise, preferred_shopfront_taxon_order: ",1,2,3")
        expect(enterprise).to be_invalid
        enterprise = build(:enterprise, preferred_shopfront_taxon_order: "1,2,3,")
        expect(enterprise).to be_invalid
      end

      it "any other characters are invalid" do
        enterprise = build(:enterprise, preferred_shopfront_taxon_order: "a1,2,3")
        expect(enterprise).to be_invalid
        enterprise = build(:enterprise, preferred_shopfront_taxon_order: ".1,2,3")
        expect(enterprise).to be_invalid
        enterprise = build(:enterprise, preferred_shopfront_taxon_order: " 1,2,3")
        expect(enterprise).to be_invalid
      end
    end
  end

  describe "delegations" do
    #subject { FactoryBot.create(:distributor_enterprise, :address => FactoryBot.create(:address)) }

    it { should delegate(:latitude).to(:address) }
    it { should delegate(:longitude).to(:address) }
    it { should delegate(:city).to(:address) }
    it { should delegate(:state_name).to(:address) }
  end

  describe "callbacks" do
    it "restores permalink to original value when it is changed and invalid" do
      e1 = create(:enterprise, permalink: "taken")
      e2 = create(:enterprise, permalink: "not_taken")
      e2.permalink = "taken"
      e2.save
      expect(e2.permalink).to eq "not_taken"
    end
  end

  describe "scopes" do
    describe 'visible' do
      it 'find visible enterprises' do
        d1 = create(:distributor_enterprise, visible: false)
        s1 = create(:supplier_enterprise)
        Enterprise.visible.should == [s1]
      end
    end

    describe "activated" do
      let!(:unconfirmed_user) { create(:user, confirmed_at: nil, enterprise_limit: 2) }
      let!(:inactive_enterprise) { create(:enterprise, sells: "unspecified") }
      let!(:active_enterprise) { create(:enterprise, sells: "none") }

      it "finds enterprises that have a sells property other than 'unspecified'" do
        activated_enterprises = Enterprise.activated
        expect(activated_enterprises).to include active_enterprise
        expect(activated_enterprises).to_not include inactive_enterprise
      end
    end

    describe "ready_for_checkout" do
      let!(:e) { create(:enterprise) }

      it "does not show enterprises with no payment methods" do
        create(:shipping_method, distributors: [e])
        Enterprise.ready_for_checkout.should_not include e
      end

      it "does not show enterprises with no shipping methods" do
        create(:payment_method, distributors: [e])
        Enterprise.ready_for_checkout.should_not include e
      end

      it "does not show enterprises with unavailable payment methods" do
        create(:shipping_method, distributors: [e])
        create(:payment_method, distributors: [e], active: false)
        Enterprise.ready_for_checkout.should_not include e
      end

      it "shows enterprises with available payment and shipping methods" do
        create(:shipping_method, distributors: [e])
        create(:payment_method, distributors: [e])
        Enterprise.ready_for_checkout.should include e
      end
    end

    describe "not_ready_for_checkout" do
      let!(:e) { create(:enterprise) }

      it "shows enterprises with no payment methods" do
        create(:shipping_method, distributors: [e])
        Enterprise.not_ready_for_checkout.should include e
      end

      it "shows enterprises with no shipping methods" do
        create(:payment_method, distributors: [e])
        Enterprise.not_ready_for_checkout.should include e
      end

      it "shows enterprises with unavailable payment methods" do
        create(:shipping_method, distributors: [e])
        create(:payment_method, distributors: [e], active: false)
        Enterprise.not_ready_for_checkout.should include e
      end

      it "does not show enterprises with available payment and shipping methods" do
        create(:shipping_method, distributors: [e])
        create(:payment_method, distributors: [e])
        Enterprise.not_ready_for_checkout.should_not include e
      end
    end

    describe "#ready_for_checkout?" do
      let!(:e) { create(:enterprise) }

      it "returns false for enterprises with no payment methods" do
        create(:shipping_method, distributors: [e])
        e.reload.should_not be_ready_for_checkout
      end

      it "returns false for enterprises with no shipping methods" do
        create(:payment_method, distributors: [e])
        e.reload.should_not be_ready_for_checkout
      end

      it "returns false for enterprises with unavailable payment methods" do
        create(:shipping_method, distributors: [e])
        create(:payment_method, distributors: [e], active: false)
        e.reload.should_not be_ready_for_checkout
      end

      it "returns true for enterprises with available payment and shipping methods" do
        create(:shipping_method, distributors: [e])
        create(:payment_method, distributors: [e])
        e.reload.should be_ready_for_checkout
      end
    end

    describe "distributors_with_active_order_cycles" do
      it "finds active distributors by order cycles" do
        s = create(:supplier_enterprise)
        d = create(:distributor_enterprise)
        p = create(:product)
        create(:simple_order_cycle, suppliers: [s], distributors: [d], variants: [p.master])
        Enterprise.distributors_with_active_order_cycles.should == [d]
      end

      it "should not find inactive distributors by order cycles" do
        s = create(:supplier_enterprise)
        d = create(:distributor_enterprise)
        p = create(:product)
        create(:simple_order_cycle, :orders_open_at => 10.days.from_now, orders_close_at: 17.days.from_now, suppliers: [s], distributors: [d], variants: [p.master])
        Enterprise.distributors_with_active_order_cycles.should_not include d
      end
    end

    describe "supplying_variant_in" do
      it "finds producers by supply of master variant" do
        s = create(:supplier_enterprise)
        p = create(:simple_product, supplier: s)

        Enterprise.supplying_variant_in([p.master]).should == [s]
      end

      it "finds producers by supply of variant" do
        s = create(:supplier_enterprise)
        p = create(:simple_product, supplier: s)
        v = create(:variant, product: p)

        Enterprise.supplying_variant_in([v]).should == [s]
      end

      it "returns multiple enterprises when given multiple variants" do
        s1 = create(:supplier_enterprise)
        s2 = create(:supplier_enterprise)
        p1 = create(:simple_product, supplier: s1)
        p2 = create(:simple_product, supplier: s2)

        Enterprise.supplying_variant_in([p1.master, p2.master]).should match_array [s1, s2]
      end

      it "does not return duplicates" do
        s = create(:supplier_enterprise)
        p1 = create(:simple_product, supplier: s)
        p2 = create(:simple_product, supplier: s)

        Enterprise.supplying_variant_in([p1.master, p2.master]).should == [s]
      end
    end

    describe "distributing_products" do
      let(:distributor) { create(:distributor_enterprise) }
      let(:product) { create(:product) }

      it "returns enterprises distributing via an order cycle" do
        order_cycle = create(:simple_order_cycle, distributors: [distributor], variants: [product.master])
        Enterprise.distributing_products(product).should == [distributor]
      end

      it "does not return duplicate enterprises" do
        another_product = create(:product)
        order_cycle = create(:simple_order_cycle, distributors: [distributor], variants: [product.master, another_product.master])
        Enterprise.distributing_products([product, another_product]).should == [distributor]
      end
    end

    describe "managed_by" do
      it "shows only enterprises for given user" do
        user = create(:user)
        user.spree_roles = []
        e1 = create(:enterprise)
        e2 = create(:enterprise)
        e1.enterprise_roles.build(user: user).save

        enterprises = Enterprise.managed_by user
        enterprises.count.should == 1
        enterprises.should include e1
      end

      it "shows all enterprises for admin user" do
        user = create(:admin_user)
        e1 = create(:enterprise)
        e2 = create(:enterprise)

        enterprises = Enterprise.managed_by user
        enterprises.count.should == 2
        enterprises.should include e1
        enterprises.should include e2
      end
    end
  end

  describe "callbacks" do
    describe "after creation" do
      let(:owner) { create(:user, enterprise_limit: 10) }
      let(:hub1) { create(:distributor_enterprise, owner: owner) }
      let(:hub2) { create(:distributor_enterprise, owner: owner) }
      let(:hub3) { create(:distributor_enterprise, owner: owner) }
      let(:producer1) { create(:supplier_enterprise, owner: owner) }
      let(:producer2) { create(:supplier_enterprise, owner: owner) }

      describe "when a producer is created" do
        before do
          hub1
          hub2
        end

        it "creates links from the new producer to all hubs owned by the same user, granting add_to_order_cycle and create_variant_overrides permissions" do
          producer1

          should_have_enterprise_relationship from: producer1, to: hub1, with: [:add_to_order_cycle, :create_variant_overrides]
          should_have_enterprise_relationship from: producer1, to: hub2, with: [:add_to_order_cycle, :create_variant_overrides]
        end

        it "does not create any other links" do
          expect do
            producer1
          end.to change(EnterpriseRelationship, :count).by(2)
        end
      end


      describe "when a new hub is created" do
        it "it creates links to the hub, from all producers owned by the same user, granting add_to_order_cycle and create_variant_overrides permissions" do
          producer1
          producer2
          hub1

          should_have_enterprise_relationship from: producer1, to: hub1, with: [:add_to_order_cycle, :create_variant_overrides]
          should_have_enterprise_relationship from: producer2, to: hub1, with: [:add_to_order_cycle, :create_variant_overrides]
        end


        it "creates links from the new hub to all hubs owned by the same user, granting add_to_order_cycle permission" do
          hub1
          hub2
          hub3

          should_have_enterprise_relationship from: hub2, to: hub1, with: [:add_to_order_cycle]
          should_have_enterprise_relationship from: hub3, to: hub1, with: [:add_to_order_cycle]
          should_have_enterprise_relationship from: hub3, to: hub2, with: [:add_to_order_cycle]
        end

        it "does not create any other links" do
          producer1
          producer2
          expect { hub1 }.to change(EnterpriseRelationship, :count).by(2) # 2 producer links
          expect { hub2 }.to change(EnterpriseRelationship, :count).by(3) # 2 producer links + 1 hub link
          expect { hub3 }.to change(EnterpriseRelationship, :count).by(4) # 2 producer links + 2 hub links
        end
      end


      def should_have_enterprise_relationship(opts={})
        er = EnterpriseRelationship.where(parent_id: opts[:from], child_id: opts[:to]).last
        er.should_not be_nil
        if opts[:with] == :all_permissions
          er.permissions.map(&:name).should match_array ['add_to_order_cycle', 'manage_products', 'edit_profile', 'create_variant_overrides']
        elsif opts.key? :with
          er.permissions.map(&:name).should match_array opts[:with].map(&:to_s)
        end
      end
    end
  end

  describe "finding variants distributed by the enterprise" do
    it "finds variants, including master, distributed by order cycle" do
      distributor = create(:distributor_enterprise)
      product = create(:product)
      variant = product.variants.first
      create(:simple_order_cycle, distributors: [distributor], variants: [variant])

      distributor.distributed_variants.should match_array [product.master, variant]
    end
  end

  describe "taxons" do
    let(:distributor) { create(:distributor_enterprise) }
    let(:supplier) { create(:supplier_enterprise) }
    let(:taxon1) { create(:taxon) }
    let(:taxon2) { create(:taxon) }
    let(:product1) { create(:simple_product, primary_taxon: taxon1, taxons: [taxon1]) }
    let(:product2) { create(:simple_product, primary_taxon: taxon1, taxons: [taxon1, taxon2]) }

    it "gets all taxons of all distributed products" do
      Spree::Product.stub(:in_distributor).and_return [product1, product2]
      distributor.distributed_taxons.should match_array [taxon1, taxon2]
    end

    it "gets all taxons of all supplied products" do
      Spree::Product.stub(:in_supplier).and_return [product1, product2]
      supplier.supplied_taxons.should match_array [taxon1, taxon2]
    end
  end

  describe "presentation of attributes" do
    let(:distributor) {
      create(:distributor_enterprise,
             website: "http://www.google.com",
             facebook: "www.facebook.com/roger",
             linkedin: "https://linkedin.com")
    }

    it "strips http from url fields" do
      distributor.website.should == "www.google.com"
      distributor.facebook.should == "www.facebook.com/roger"
      distributor.linkedin.should == "linkedin.com"
    end
  end

  describe "producer properties" do
    let(:supplier) { create(:supplier_enterprise) }

    it "sets producer properties" do
      supplier.set_producer_property 'Organic Certified', 'NASAA 12345'

      supplier.producer_properties.count.should == 1
      supplier.producer_properties.first.value.should == 'NASAA 12345'
      supplier.producer_properties.first.property.presentation.should == 'Organic Certified'
    end
  end

  describe "provide enterprise category" do
    let(:producer_sell_all) { build(:enterprise, is_primary_producer: true,  sells: "any") }
    let(:producer_sell_own) { build(:enterprise, is_primary_producer: true,  sells: "own") }
    let(:producer_sell_none) { build(:enterprise, is_primary_producer: true,  sells: "none") }
    let(:non_producer_sell_all) { build(:enterprise, is_primary_producer: false,  sells: "any") }
    let(:non_producer_sell_own) { build(:enterprise, is_primary_producer: false,  sells: "own") }
    let(:non_producer_sell_none) { build(:enterprise, is_primary_producer: false, sells: "none") }

    it "should output enterprise categories" do
      producer_sell_all.is_primary_producer.should == true
      producer_sell_all.sells.should == "any"

      producer_sell_all.category.should == :producer_hub
      producer_sell_own.category.should == :producer_shop
      producer_sell_none.category.should == :producer
      non_producer_sell_all.category.should == :hub
      non_producer_sell_own.category.should == :hub
      non_producer_sell_none.category.should == :hub_profile
    end
  end

  describe "finding and automatically assigning a permalink" do
    let(:enterprise) { build(:enterprise, name: "Name To Turn Into A Permalink") }
    it "assigns permalink when initialized" do
      allow(Enterprise).to receive(:find_available_permalink).and_return("available_permalink")
      Enterprise.should_receive(:find_available_permalink).with("Name To Turn Into A Permalink")
      expect(
        lambda { enterprise.send(:initialize_permalink) }
      ).to change{
        enterprise.permalink
      }.to(
        "available_permalink"
      )
    end

    describe "finding a permalink" do
      let!(:enterprise1) { create(:enterprise, permalink: "permalink") }
      let!(:enterprise2) { create(:enterprise, permalink: "permalink1") }

      it "parameterizes the value provided" do
        expect(Enterprise.find_available_permalink("Some Unused Permalink")).to eq "some-unused-permalink"
      end

      it "sets the permalink to 'my-enterprise' if parametized permalink is blank" do
        expect(Enterprise.find_available_permalink("")).to eq "my-enterprise"
        expect(Enterprise.find_available_permalink("$$%{$**}$%}")).to eq "my-enterprise"
      end

      it "finds and index value based on existing permalinks" do
        expect(Enterprise.find_available_permalink("permalink")).to eq "permalink2"
      end

      it "ignores permalinks with characters after the index value" do
        create(:enterprise, permalink: "permalink2xxx")
        expect(Enterprise.find_available_permalink("permalink")).to eq "permalink2"
      end

      it "finds available permalink similar to existing" do
        create(:enterprise, permalink: "permalink2xxx")
        expect(Enterprise.find_available_permalink("permalink2")).to eq "permalink2"
      end

      it "finds gaps in the indices of existing permalinks" do
        create(:enterprise, permalink: "permalink3")
        expect(Enterprise.find_available_permalink("permalink")).to eq "permalink2"
      end
    end
  end
end
